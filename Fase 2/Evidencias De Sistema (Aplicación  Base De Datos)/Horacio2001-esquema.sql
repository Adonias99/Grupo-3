


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "vector" WITH SCHEMA "public";






CREATE OR REPLACE FUNCTION "public"."actualizar_metadata_producto"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
  v_marca text;
  v_color text;
  v_categoria text;
  v_stock jsonb;
BEGIN
  IF NEW.marca_id IS NOT NULL THEN
    SELECT nombre INTO v_marca FROM public.marcas WHERE id = NEW.marca_id;
  END IF;
  IF NEW.color_id IS NOT NULL THEN
    SELECT nombre INTO v_color FROM public.colores WHERE id = NEW.color_id;
  END IF;
  IF NEW.categoria_id IS NOT NULL THEN
    SELECT nombre INTO v_categoria FROM public.categorias WHERE id = NEW.categoria_id;
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('talla', talla, 'cantidad', cantidad)), '[]'::jsonb)
    INTO v_stock
    FROM public.stock WHERE producto_id = NEW.id;
  NEW.metadata = jsonb_build_object(
    'nombre', NEW.nombre,
    'precio', NEW.precio,
    'precio_oferta', NEW.precio_oferta,
    'en_oferta', NEW.en_oferta,
    'imagen_url', NEW.imagen_url,
    'marca', v_marca,
    'color', v_color,
    'categoria', v_categoria,
    'stock', COALESCE(v_stock, '[]'::jsonb)
  );
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."actualizar_metadata_producto"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."adquirir_tarea_comprobante"() RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
  tarea public.comprobante_tareas%ROWTYPE;
  documento public.comprobantes%ROWTYPE;
BEGIN
  -- Evitar reenvíos automáticos fuera de la ventana
  -- de idempotencia del proveedor de correo.
  UPDATE public.comprobante_tareas t
  SET
    estado = 'revision_manual',
    token_bloqueo = NULL,
    bloqueado_hasta = NULL,
    updated_at = now()
  WHERE t.tipo = 'enviar_correo'
    AND t.estado IN ('pendiente', 'error', 'procesando')
    AND (
      t.bloqueado_hasta IS NULL
      OR t.bloqueado_hasta < now()
    )
    AND t.primer_intento_at
      < now() - interval '23 hours 30 minutes';

  -- Detener tareas que agotaron sus intentos.
  UPDATE public.comprobante_tareas
  SET
    estado = 'revision_manual',
    token_bloqueo = NULL,
    bloqueado_hasta = NULL,
    updated_at = now()
  WHERE estado = 'procesando'
    AND bloqueado_hasta < now()
    AND intentos >= max_intentos;

  SELECT t.*
  INTO tarea
  FROM public.comprobante_tareas t
  JOIN public.comprobantes c
    ON c.id = t.comprobante_id
  JOIN public.pedidos p
    ON p.id = c.pedido_id
  WHERE c.estado_documento = 'vigente'
    AND p.estado = 'exitoso'
    AND t.estado IN ('pendiente', 'error', 'procesando')
    AND t.intentos < t.max_intentos
    AND t.proximo_intento_at <= now()
    AND (
      t.bloqueado_hasta IS NULL
      OR t.bloqueado_hasta < now()
    )
    AND (
      t.tipo = 'generar_pdf'
      OR c.estado_pdf = 'disponible'
    )
  ORDER BY t.created_at, t.id
  FOR UPDATE OF c, t SKIP LOCKED
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  UPDATE public.comprobante_tareas
  SET
    estado = 'procesando',
    intentos = intentos + 1,
    primer_intento_at = coalesce(primer_intento_at, now()),
    token_bloqueo = gen_random_uuid(),
    bloqueado_hasta = now() + interval '120 seconds',
    updated_at = now()
  WHERE id = tarea.id
  RETURNING * INTO tarea;

  UPDATE public.comprobantes
  SET
    estado_pdf = CASE
      WHEN tarea.tipo = 'generar_pdf' THEN 'generando'
      ELSE estado_pdf
    END,
    estado_correo = CASE
      WHEN tarea.tipo = 'enviar_correo' THEN 'enviando'
      ELSE estado_correo
    END,
    updated_at = now()
  WHERE id = tarea.comprobante_id
  RETURNING * INTO documento;

  RETURN jsonb_build_object(
    'tarea', to_jsonb(tarea),
    'comprobante', to_jsonb(documento)
  );
END;
$$;


ALTER FUNCTION "public"."adquirir_tarea_comprobante"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."crear_pedido_comprobante"("p_perfil_id" "uuid", "p_snapshot" "jsonb", "p_envio" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
  pedido public.pedidos%ROWTYPE;
  metodo public.metodos_pago.id%TYPE;
  producto public.productos%ROWTYPE;
  v_producto_id public.productos.id%TYPE;
  v_tipo_envio public.envios.tipo_envio%TYPE;
  linea jsonb;
  cantidad integer;
  disponibles integer;
  precio bigint;
  suma bigint := 0;
BEGIN
  -- Validar moneda y líneas de la compra.
  IF p_snapshot->>'moneda' IS DISTINCT FROM 'CLP'
     OR jsonb_typeof(p_snapshot->'lineas')
          IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_snapshot->'lineas')
          NOT BETWEEN 1 AND 100
  THEN
    RAISE EXCEPTION 'Snapshot inválido'
      USING ERRCODE = '23514';
  END IF;

  -- Buscar el método de pago existente.
  SELECT id
  INTO metodo
  FROM public.metodos_pago
  WHERE lower(nombre) LIKE '%mercado%pago%'
  ORDER BY id
  LIMIT 1;

  IF metodo IS NULL THEN
    RAISE EXCEPTION 'Configurar método Mercado Pago'
      USING ERRCODE = '23514';
  END IF;

  -- Revalidar precios y disponibilidad.
  -- Esta función no descuenta ni reserva stock.
  FOR linea IN
    SELECT value
    FROM jsonb_array_elements(p_snapshot->'lineas')
    ORDER BY value->>'producto_id', value->>'talla'
  LOOP
    v_producto_id := linea->>'producto_id';
    cantidad := (linea->>'cantidad')::integer;

    SELECT *
    INTO producto
    FROM public.productos
    WHERE id = v_producto_id
    FOR SHARE;

    IF NOT FOUND OR cantidad NOT BETWEEN 1 AND 50 THEN
      RAISE EXCEPTION 'Producto/cantidad inválidos'
        USING ERRCODE = '23514';
    END IF;

    SELECT s.cantidad
    INTO disponibles
    FROM public.stock s
    WHERE s.producto_id = v_producto_id
      AND s.talla = linea->>'talla'
    FOR SHARE;

    precio := CASE
      WHEN producto.en_oferta
        THEN producto.precio_oferta
      ELSE producto.precio
    END;

    IF disponibles IS NULL
       OR disponibles < cantidad
       OR precio IS NULL
       OR precio <= 0
       OR precio <> (linea->>'precio_unitario')::bigint
       OR precio * cantidad <> (linea->>'total_linea')::bigint
    THEN
      RAISE EXCEPTION 'Stock o precio cambió'
        USING ERRCODE = '23514';
    END IF;

    suma := suma + precio * cantidad;
  END LOOP;

  -- Validar importes.
  IF suma <> (p_snapshot->>'subtotal')::bigint
     OR (p_snapshot->>'descuento')::bigint <> 0
     OR suma + (p_snapshot->>'costo_envio')::bigint
          <> (p_snapshot->>'total')::bigint
  THEN
    RAISE EXCEPTION 'Importes inválidos'
      USING ERRCODE = '23514';
  END IF;

  -- Crear pedido pendiente y conservar su snapshot.
  INSERT INTO public.pedidos (
    perfil_id,
    nombre_cliente,
    email,
    telefono,
    total,
    estado,
    metodo_pago_id,
    compra_snapshot
  )
  VALUES (
    p_perfil_id,
    p_snapshot #>> '{cliente,nombre}',
    p_snapshot #>> '{cliente,email}',
    p_envio->>'telefono',
    (p_snapshot->>'total')::bigint,
    'pendiente',
    metodo,
    p_snapshot
  )
  RETURNING * INTO pedido;

  -- Guardar los productos y tallas.
  FOR linea IN
    SELECT value
    FROM jsonb_array_elements(p_snapshot->'lineas')
  LOOP
    v_producto_id := linea->>'producto_id';

    INSERT INTO public.detalles_pedido (
      pedido_id,
      producto_id,
      cantidad,
      precio_unitario,
      talla
    )
    VALUES (
      pedido.id,
      v_producto_id,
      (linea->>'cantidad')::integer,
      (linea->>'precio_unitario')::bigint,
      linea->>'talla'
    );
  END LOOP;

  -- Guardar el envío.
  v_tipo_envio := p_snapshot->>'tipo_envio';

  INSERT INTO public.envios (
    pedido_id,
    tipo_envio,
    estado_logistico,
    nombre_destinatario,
    rut_destinatario,
    telefono_contacto,
    direccion,
    region_id,
    comuna_id,
    estacion_metro,
    costo_envio
  )
  VALUES (
    pedido.id,
    v_tipo_envio,
    'preparacion',
    p_snapshot #>> '{cliente,nombre}',
    nullif(p_envio->>'rut', ''),
    p_envio->>'telefono',
    nullif(p_envio->>'direccion', ''),
    nullif(p_envio->>'region', '')::bigint,
    nullif(p_envio->>'comuna', '')::bigint,
    nullif(p_envio->>'estacionMetro', ''),
    (p_snapshot->>'costo_envio')::bigint
  );

  RETURN jsonb_build_object(
    'pedido_id',
    pedido.id::text
  );
END;
$$;


ALTER FUNCTION "public"."crear_pedido_comprobante"("p_perfil_id" "uuid", "p_snapshot" "jsonb", "p_envio" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fallar_tarea_comprobante"("p_tarea" "uuid", "p_token" "uuid", "p_codigo" "text", "p_revision" boolean DEFAULT false, "p_incierto" boolean DEFAULT false) RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
  tarea public.comprobante_tareas%ROWTYPE;
BEGIN
  SELECT *
  INTO tarea
  FROM public.comprobante_tareas
  WHERE id = p_tarea;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tarea inexistente'
      USING ERRCODE = '55000';
  END IF;

  PERFORM 1
  FROM public.comprobantes
  WHERE id = tarea.comprobante_id
  FOR UPDATE;

  SELECT *
  INTO tarea
  FROM public.comprobante_tareas
  WHERE id = p_tarea
  FOR UPDATE;

  -- Un proceso antiguo no puede liberar la tarea de otro.
  IF NOT FOUND
     OR tarea.estado <> 'procesando'
     OR tarea.token_bloqueo IS DISTINCT FROM p_token
  THEN
    RETURN;
  END IF;

  UPDATE public.comprobante_tareas
  SET
    estado = CASE
      WHEN p_revision OR intentos >= max_intentos
        THEN 'revision_manual'
      ELSE 'error'
    END,
    proximo_intento_at = now() + make_interval(
      secs => least(
        3600,
        30 * power(2, least(intentos, 6))
      )::integer
    ),
    token_bloqueo = NULL,
    bloqueado_hasta = NULL,
    ultimo_error_codigo = left(p_codigo, 80),
    ultimo_error_resumen =
      'La operación requiere reintento o revisión; no se almacenan respuestas sensibles.',
    updated_at = now()
  WHERE id = tarea.id;

  UPDATE public.comprobantes
  SET
    estado_pdf = CASE
      WHEN tarea.tipo = 'generar_pdf' THEN 'error'
      ELSE estado_pdf
    END,
    estado_correo = CASE
      WHEN tarea.tipo = 'enviar_correo' THEN
        CASE
          WHEN p_incierto THEN 'envio_incierto'
          ELSE 'error'
        END
      ELSE estado_correo
    END,
    updated_at = now()
  WHERE id = tarea.comprobante_id;
END;
$$;


ALTER FUNCTION "public"."fallar_tarea_comprobante"("p_tarea" "uuid", "p_token" "uuid", "p_codigo" "text", "p_revision" boolean, "p_incierto" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."finalizar_tarea_comprobante"("p_tarea" "uuid", "p_token" "uuid", "p_resultado" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
  tarea public.comprobante_tareas%ROWTYPE;
  documento public.comprobantes%ROWTYPE;
BEGIN
  SELECT *
  INTO tarea
  FROM public.comprobante_tareas
  WHERE id = p_tarea;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tarea inexistente'
      USING ERRCODE = '55000';
  END IF;

  PERFORM 1
  FROM public.comprobantes
  WHERE id = tarea.comprobante_id
  FOR UPDATE;

  SELECT *
  INTO tarea
  FROM public.comprobante_tareas
  WHERE id = p_tarea
  FOR UPDATE;

  IF NOT FOUND
     OR tarea.estado <> 'procesando'
     OR tarea.token_bloqueo IS DISTINCT FROM p_token
     OR tarea.bloqueado_hasta < now()
  THEN
    RAISE EXCEPTION 'Lease inválido'
      USING ERRCODE = '55000';
  END IF;

  SELECT *
  INTO documento
  FROM public.comprobantes
  WHERE id = tarea.comprobante_id
  FOR UPDATE;

  IF documento.estado_documento <> 'vigente' THEN
    RAISE EXCEPTION 'Documento anulado'
      USING ERRCODE = '55000';
  END IF;

  IF tarea.tipo = 'generar_pdf' THEN
    UPDATE public.comprobantes
    SET
      estado_pdf = 'disponible',
      storage_path = p_resultado->>'storage_path',
      pdf_sha256 = p_resultado->>'sha256',
      emitido_at = (p_resultado->>'emitido_at')::timestamptz,
      updated_at = now()
    WHERE id = documento.id;

    -- Una vez listo el PDF, dejar pendiente el correo.
    INSERT INTO public.comprobante_tareas (
      comprobante_id,
      tipo,
      clave_idempotencia
    )
    VALUES (
      documento.id,
      'enviar_correo',
      'comprobante/' || documento.id::text || '/correo/v1'
    )
    ON CONFLICT (comprobante_id, tipo) DO NOTHING;

  ELSE
    IF nullif(p_resultado->>'proveedor_id', '') IS NULL THEN
      RAISE EXCEPTION 'Falta referencia del correo'
        USING ERRCODE = '23514';
    END IF;

    UPDATE public.comprobantes
    SET
      estado_correo = 'aceptado',
      correo_proveedor_id = p_resultado->>'proveedor_id',
      correo_aceptado_at = now(),
      updated_at = now()
    WHERE id = documento.id;
  END IF;

  UPDATE public.comprobante_tareas
  SET
    estado = 'completada',
    completed_at = now(),
    token_bloqueo = NULL,
    bloqueado_hasta = NULL,
    ultimo_error_codigo = NULL,
    ultimo_error_resumen = NULL,
    updated_at = now()
  WHERE id = tarea.id;
END;
$$;


ALTER FUNCTION "public"."finalizar_tarea_comprobante"("p_tarea" "uuid", "p_token" "uuid", "p_resultado" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."match_productos"("query_embedding" "public"."vector", "match_count" integer DEFAULT 5, "filter" "jsonb" DEFAULT '{}'::"jsonb") RETURNS TABLE("id" bigint, "nombre" "text", "metadata" "jsonb", "similarity" double precision)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY
  SELECT
    productos.id,
    productos.nombre,
    productos.metadata,
    1 - (productos.embedding <=> query_embedding) AS similarity
  FROM productos
  ORDER BY productos.embedding <=> query_embedding
  LIMIT match_count;
END;
$$;


ALTER FUNCTION "public"."match_productos"("query_embedding" "public"."vector", "match_count" integer, "filter" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recalcular_metadata_por_stock"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    UPDATE public.productos SET id = id WHERE id = OLD.producto_id;
    RETURN OLD;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.producto_id IS DISTINCT FROM NEW.producto_id THEN
    UPDATE public.productos SET id = id WHERE id = OLD.producto_id;
  END IF;
  UPDATE public.productos SET id = id WHERE id = NEW.producto_id;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."recalcular_metadata_por_stock"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."registrar_pago_comprobante"("p_pago" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $_$
DECLARE
  linea record;
  disponibles integer;
  faltante boolean := false;
  pedido public.pedidos%ROWTYPE;
  documento public.comprobantes%ROWTYPE;
  estado_pago text := p_pago->>'status';
  pago_id text := p_pago->>'id';
  fecha timestamptz := (p_pago->>'fecha_aprobacion')::timestamptz;
BEGIN
  SELECT * INTO pedido
  FROM public.pedidos
  WHERE id::text = p_pago->>'pedido_id'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pedido no encontrado' USING ERRCODE = 'P0002';
  END IF;
  IF (p_pago->>'monto')::numeric <> pedido.total
     OR p_pago->>'moneda' IS DISTINCT FROM 'CLP' THEN
    RAISE EXCEPTION 'Importe/moneda no coinciden' USING ERRCODE = '23514';
  END IF;

  SELECT * INTO documento
  FROM public.comprobantes
  WHERE pedido_id = pedido.id
  FOR UPDATE;
  IF documento.id IS NOT NULL AND documento.pago_id <> pago_id THEN
    IF estado_pago IN ('approved','refunded','charged_back') THEN
      RAISE EXCEPTION 'Pago diferente para el mismo pedido' USING ERRCODE = '23505';
    END IF;
    RETURN jsonb_build_object('estado','ignorado');
  END IF;

  IF estado_pago IN ('refunded','charged_back') THEN
    UPDATE public.pedidos SET estado = 'erroneo' WHERE id = pedido.id;
    IF documento.id IS NOT NULL THEN
      UPDATE public.comprobantes
      SET estado_documento = 'anulado',
          anulado_at = coalesce(anulado_at, now()),
          estado_correo = CASE
            WHEN estado_correo IN ('pendiente','error') THEN 'cancelado'
            ELSE estado_correo
          END,
          updated_at = now()
      WHERE id = documento.id;
      UPDATE public.comprobante_tareas
      SET estado = 'cancelada', token_bloqueo = NULL,
          bloqueado_hasta = NULL, updated_at = now()
      WHERE comprobante_id = documento.id
        AND estado NOT IN ('completada','cancelada');
    END IF;
    RETURN jsonb_build_object('estado','anulado');
  END IF;

  IF estado_pago <> 'approved' THEN
    IF documento.id IS NULL AND pedido.estado <> 'exitoso'
       AND estado_pago IN ('rejected','cancelled') THEN
      UPDATE public.pedidos SET estado = 'erroneo' WHERE id = pedido.id;
    END IF;
    RETURN jsonb_build_object('estado','sin_emision');
  END IF;

  IF coalesce((p_pago->>'monto_reembolsado')::numeric, 0) > 0 THEN
    IF documento.id IS NOT NULL THEN
      UPDATE public.comprobante_tareas
      SET estado = 'revision_manual', ultimo_error_codigo = 'PARTIAL_REFUND',
          token_bloqueo = NULL, bloqueado_hasta = NULL, updated_at = now()
      WHERE comprobante_id = documento.id
        AND estado NOT IN ('completada','cancelada');
    END IF;
    RETURN jsonb_build_object('estado','reembolso_parcial_revision');
  END IF;

  IF documento.id IS NOT NULL THEN
    RETURN jsonb_build_object('estado','existente','comprobante_id',documento.id);
  END IF;
  IF pedido.compra_snapshot IS NULL OR fecha IS NULL
     OR (pedido.compra_snapshot->>'total')::numeric <> pedido.total THEN
    RAISE EXCEPTION 'Pedido sin snapshot íntegro' USING ERRCODE = '23514';
  END IF;
  IF jsonb_typeof(pedido.compra_snapshot->'lineas') IS DISTINCT FROM 'array'
     OR jsonb_array_length(pedido.compra_snapshot->'lineas') = 0 THEN
    RAISE EXCEPTION 'Pedido sin líneas de stock' USING ERRCODE = '23514';
  END IF;

  -- Bloqueo ordenado de productos y tallas; ningún descuento parcial.
  FOR linea IN
    SELECT value->>'producto_id' AS producto_id,
           value->>'talla' AS talla,
           sum((value->>'cantidad')::integer)::integer AS cantidad
    FROM jsonb_array_elements(pedido.compra_snapshot->'lineas')
    GROUP BY 1,2 ORDER BY 1,2
  LOOP
    IF linea.producto_id IS NULL OR linea.talla IS NULL
       OR linea.cantidad IS NULL OR linea.cantidad <= 0 THEN
      RAISE EXCEPTION 'Línea de stock inválida' USING ERRCODE = '23514';
    END IF;
    PERFORM 1 FROM public.productos
      WHERE id::text = linea.producto_id FOR UPDATE;
    SELECT cantidad INTO disponibles FROM public.stock
      WHERE producto_id::text = linea.producto_id AND talla = linea.talla
      FOR UPDATE;
    IF NOT FOUND OR disponibles IS NULL OR disponibles < linea.cantidad THEN
      faltante := true;
    END IF;
  END LOOP;

  IF NOT faltante AND pedido.stock_descontado_at IS NULL
     AND pedido.estado_stock <> 'anterior' THEN
    FOR linea IN
      SELECT value->>'producto_id' AS producto_id,
             value->>'talla' AS talla,
             sum((value->>'cantidad')::integer)::integer AS cantidad
      FROM jsonb_array_elements(pedido.compra_snapshot->'lineas')
      GROUP BY 1,2 ORDER BY 1,2
    LOOP
      UPDATE public.stock
      SET cantidad = cantidad - linea.cantidad
      WHERE producto_id::text = linea.producto_id AND talla = linea.talla;
    END LOOP;
    UPDATE public.pedidos
    SET estado_stock = 'descontado', stock_descontado_at = now()
    WHERE id = pedido.id;
  ELSIF faltante AND pedido.stock_descontado_at IS NULL
        AND pedido.estado_stock <> 'anterior' THEN
    UPDATE public.pedidos SET estado_stock = 'insuficiente' WHERE id = pedido.id;
  END IF;

  UPDATE public.pedidos SET estado = 'exitoso' WHERE id = pedido.id;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_attribute
    WHERE attrelid = 'public.pedidos'::regclass
      AND attname = 'fecha_pago' AND NOT attisdropped
  ) THEN
    EXECUTE 'UPDATE public.pedidos SET fecha_pago = coalesce(fecha_pago,$1) WHERE id::text = $2'
      USING fecha, pedido.id::text;
  END IF;

  INSERT INTO public.comprobantes(pedido_id,pago_id,datos_emision,email_destinatario)
  VALUES (pedido.id,pago_id,
          pedido.compra_snapshot || jsonb_build_object('fecha_pago',fecha),
          pedido.compra_snapshot #>> '{cliente,email}')
  RETURNING * INTO documento;
  INSERT INTO public.comprobante_tareas(comprobante_id,tipo,clave_idempotencia)
  VALUES (documento.id,'generar_pdf','comprobante/' || documento.id::text || '/pdf/v1');
  RETURN jsonb_build_object('estado','registrado','comprobante_id',documento.id);
END;
$_$;


ALTER FUNCTION "public"."registrar_pago_comprobante"("p_pago" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."resumen_ventas_dashboard"() RETURNS "jsonb"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
  SELECT jsonb_build_object(
    'total_ventas', coalesce(sum(total) FILTER (WHERE estado = 'exitoso'), 0),
    'exitosos', count(*) FILTER (WHERE estado = 'exitoso'),
    'pendientes', count(*) FILTER (WHERE estado = 'pendiente'),
    'fallidos', count(*) FILTER (WHERE estado IN ('erroneo','fallido'))
  )
  FROM public.pedidos;
$$;


ALTER FUNCTION "public"."resumen_ventas_dashboard"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."categorias" (
    "id" bigint NOT NULL,
    "nombre" "text",
    "slug" "text",
    "imagen_url" "text",
    "imagen_portada" "text"
);


ALTER TABLE "public"."categorias" OWNER TO "postgres";


ALTER TABLE "public"."categorias" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."categorias_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."colores" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nombre" "text",
    "hex" "text"
);


ALTER TABLE "public"."colores" OWNER TO "postgres";


ALTER TABLE "public"."colores" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."colores_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."comprobante_tareas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "comprobante_id" "uuid" NOT NULL,
    "tipo" "text" NOT NULL,
    "estado" "text" DEFAULT 'pendiente'::"text" NOT NULL,
    "clave_idempotencia" "text" NOT NULL,
    "intentos" integer DEFAULT 0 NOT NULL,
    "max_intentos" integer DEFAULT 6 NOT NULL,
    "proximo_intento_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "primer_intento_at" timestamp with time zone,
    "bloqueado_hasta" timestamp with time zone,
    "token_bloqueo" "uuid",
    "ultimo_error_codigo" "text",
    "ultimo_error_resumen" "text",
    "completed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "comprobante_tareas_clave_idempotencia_check" CHECK ((("length"("clave_idempotencia") >= 1) AND ("length"("clave_idempotencia") <= 256))),
    CONSTRAINT "comprobante_tareas_estado_check" CHECK (("estado" = ANY (ARRAY['pendiente'::"text", 'procesando'::"text", 'completada'::"text", 'error'::"text", 'revision_manual'::"text", 'cancelada'::"text"]))),
    CONSTRAINT "comprobante_tareas_intentos_check" CHECK (("intentos" >= 0)),
    CONSTRAINT "comprobante_tareas_max_intentos_check" CHECK (("max_intentos" > 0)),
    CONSTRAINT "comprobante_tareas_tipo_check" CHECK (("tipo" = ANY (ARRAY['generar_pdf'::"text", 'enviar_correo'::"text"])))
);


ALTER TABLE "public"."comprobante_tareas" OWNER TO "postgres";


COMMENT ON TABLE "public"."comprobante_tareas" IS 'Cola persistente para generar PDF y enviar correo con reintentos.';



CREATE TABLE IF NOT EXISTS "public"."comprobantes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "numero" bigint NOT NULL,
    "pedido_id" "uuid" NOT NULL,
    "pago_id" "text" NOT NULL,
    "tipo" "text" DEFAULT 'comprobante_compra'::"text" NOT NULL,
    "version_plantilla" integer DEFAULT 1 NOT NULL,
    "estado_documento" "text" DEFAULT 'vigente'::"text" NOT NULL,
    "datos_emision" "jsonb" NOT NULL,
    "email_destinatario" "text" NOT NULL,
    "estado_pdf" "text" DEFAULT 'pendiente'::"text" NOT NULL,
    "storage_bucket" "text" DEFAULT 'comprobantes'::"text" NOT NULL,
    "storage_path" "text",
    "pdf_sha256" "text",
    "estado_correo" "text" DEFAULT 'pendiente'::"text" NOT NULL,
    "correo_proveedor_id" "text",
    "correo_aceptado_at" timestamp with time zone,
    "emitido_at" timestamp with time zone,
    "anulado_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "comprobantes_datos_emision_check" CHECK ((("jsonb_typeof"("datos_emision") = 'object'::"text") AND ("datos_emision" <> '{}'::"jsonb"))),
    CONSTRAINT "comprobantes_email_destinatario_check" CHECK ((("length"("email_destinatario") >= 3) AND ("length"("email_destinatario") <= 320))),
    CONSTRAINT "comprobantes_estado_correo_check" CHECK (("estado_correo" = ANY (ARRAY['pendiente'::"text", 'enviando'::"text", 'aceptado'::"text", 'entregado'::"text", 'error'::"text", 'envio_incierto'::"text", 'cancelado'::"text"]))),
    CONSTRAINT "comprobantes_estado_documento_check" CHECK (("estado_documento" = ANY (ARRAY['vigente'::"text", 'anulado'::"text"]))),
    CONSTRAINT "comprobantes_estado_pdf_check" CHECK (("estado_pdf" = ANY (ARRAY['pendiente'::"text", 'generando'::"text", 'disponible'::"text", 'error'::"text"]))),
    CONSTRAINT "comprobantes_pdf_disponible" CHECK ((("estado_pdf" <> 'disponible'::"text") OR (("storage_path" IS NOT NULL) AND ("pdf_sha256" IS NOT NULL) AND ("emitido_at" IS NOT NULL)))),
    CONSTRAINT "comprobantes_pdf_sha256_check" CHECK ((("pdf_sha256" IS NULL) OR ("pdf_sha256" ~ '^[0-9a-f]{64}$'::"text"))),
    CONSTRAINT "comprobantes_storage_bucket_check" CHECK (("storage_bucket" = 'comprobantes'::"text")),
    CONSTRAINT "comprobantes_tipo_check" CHECK (("tipo" = 'comprobante_compra'::"text")),
    CONSTRAINT "comprobantes_version_plantilla_check" CHECK (("version_plantilla" > 0))
);


ALTER TABLE "public"."comprobantes" OWNER TO "postgres";


COMMENT ON TABLE "public"."comprobantes" IS 'Comprobantes académicos sin validez tributaria. Acceso mediante backend.';



ALTER TABLE "public"."comprobantes" ALTER COLUMN "numero" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."comprobantes_numero_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."comunas" (
    "id" bigint NOT NULL,
    "nombre" "text" NOT NULL,
    "region_id" bigint NOT NULL
);


ALTER TABLE "public"."comunas" OWNER TO "postgres";


ALTER TABLE "public"."comunas" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."comunas_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."detalles_pedido" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "pedido_id" "uuid" NOT NULL,
    "producto_id" bigint NOT NULL,
    "cantidad" integer DEFAULT 1 NOT NULL,
    "talla" "text" NOT NULL,
    "precio_unitario" bigint NOT NULL
);


ALTER TABLE "public"."detalles_pedido" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."direcciones" (
    "id" bigint NOT NULL,
    "perfil_id" "uuid" NOT NULL,
    "nombre_direccion" "text" DEFAULT 'Casa 1'::"text" NOT NULL,
    "nombre_destinatario" "text",
    "telefono_contacto" "text",
    "direccion" "text" NOT NULL,
    "depto_oficina" "text",
    "region_id" bigint,
    "comuna_id" bigint,
    "es_principal" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL
);


ALTER TABLE "public"."direcciones" OWNER TO "postgres";


ALTER TABLE "public"."direcciones" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."direcciones_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."envios" (
    "id" bigint NOT NULL,
    "pedido_id" "uuid",
    "tipo_envio" "text" NOT NULL,
    "estado_logistico" "text" DEFAULT 'pendiente'::"text",
    "nombre_destinatario" "text",
    "rut_destinatario" "text",
    "telefono_contacto" "text",
    "direccion" "text",
    "region_id" bigint,
    "comuna_id" bigint,
    "estacion_metro" "text",
    "proveedor_logistica" "text" DEFAULT 'Interno'::"text",
    "codigo_seguimiento" "text",
    "costo_envio" numeric DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL
);


ALTER TABLE "public"."envios" OWNER TO "postgres";


ALTER TABLE "public"."envios" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."envios_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."generos" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "nombre" "text" NOT NULL,
    "slug" "text" NOT NULL
);


ALTER TABLE "public"."generos" OWNER TO "postgres";


ALTER TABLE "public"."generos" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."generos_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."items_carrito" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "talla" "text",
    "cantidad" integer,
    "perfil_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "producto_id" bigint NOT NULL
);


ALTER TABLE "public"."items_carrito" OWNER TO "postgres";


ALTER TABLE "public"."items_carrito" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."items_carrito_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."marcas" (
    "id" bigint NOT NULL,
    "nombre" "text",
    "logo_url" "text",
    "slug" "text",
    "imagen_portada" "text"
);


ALTER TABLE "public"."marcas" OWNER TO "postgres";


ALTER TABLE "public"."marcas" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."marcas_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."metodos_pago" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nombre" "text" NOT NULL,
    "activo" boolean NOT NULL
);


ALTER TABLE "public"."metodos_pago" OWNER TO "postgres";


COMMENT ON TABLE "public"."metodos_pago" IS 'la columba activo es por si un dia desactivas un metodo de pago o agregas otro';



ALTER TABLE "public"."metodos_pago" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."metodos_pago_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."pedidos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "perfil_id" "uuid",
    "nombre_cliente" "text" NOT NULL,
    "email" "text" NOT NULL,
    "telefono" "text" NOT NULL,
    "total" bigint NOT NULL,
    "estado" "text" DEFAULT 'pendiente'::"text",
    "metodo_pago_id" bigint,
    "fecha_pago" timestamp with time zone,
    "compra_snapshot" "jsonb",
    "estado_stock" "text" DEFAULT 'pendiente'::"text" NOT NULL,
    "stock_descontado_at" timestamp with time zone,
    CONSTRAINT "pedidos_estado_stock_check" CHECK (("estado_stock" = ANY (ARRAY['pendiente'::"text", 'descontado'::"text", 'insuficiente'::"text", 'anterior'::"text"])))
);


ALTER TABLE "public"."pedidos" OWNER TO "postgres";


COMMENT ON COLUMN "public"."pedidos"."compra_snapshot" IS 'Datos de la compra calculados y congelados por el servidor antes del pago.';



CREATE TABLE IF NOT EXISTS "public"."perfiles" (
    "id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "rut" "text",
    "nombres" "text",
    "apellidos" "text",
    "email" "text",
    "telefono" "text"
);


ALTER TABLE "public"."perfiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."productos" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "precio" bigint DEFAULT '0'::bigint NOT NULL,
    "imagen_url" "text",
    "precio_oferta" bigint DEFAULT '0'::bigint,
    "en_oferta" boolean DEFAULT false NOT NULL,
    "marca_id" bigint,
    "categoria_id" bigint,
    "nombre" "text",
    "descripcion" "text",
    "color_id" bigint,
    "embedding" "public"."vector"(3072),
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "genero_id" bigint
);


ALTER TABLE "public"."productos" OWNER TO "postgres";


ALTER TABLE "public"."productos" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."productos_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."regiones" (
    "id" bigint NOT NULL,
    "nombre" "text" NOT NULL,
    "orden" integer
);


ALTER TABLE "public"."regiones" OWNER TO "postgres";


ALTER TABLE "public"."regiones" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."regiones_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."stock" (
    "id" bigint NOT NULL,
    "producto_id" bigint NOT NULL,
    "talla" "text" NOT NULL,
    "cantidad" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "stock_cantidad_no_negativa" CHECK (("cantidad" >= 0))
);


ALTER TABLE "public"."stock" OWNER TO "postgres";


ALTER TABLE "public"."stock" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."stock_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE ONLY "public"."categorias"
    ADD CONSTRAINT "categorias_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."colores"
    ADD CONSTRAINT "colores_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."comprobante_tareas"
    ADD CONSTRAINT "comprobante_tareas_clave_idempotencia_key" UNIQUE ("clave_idempotencia");



ALTER TABLE ONLY "public"."comprobante_tareas"
    ADD CONSTRAINT "comprobante_tareas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."comprobante_tareas"
    ADD CONSTRAINT "comprobante_tareas_un_tipo" UNIQUE ("comprobante_id", "tipo");



ALTER TABLE ONLY "public"."comprobantes"
    ADD CONSTRAINT "comprobantes_numero_key" UNIQUE ("numero");



ALTER TABLE ONLY "public"."comprobantes"
    ADD CONSTRAINT "comprobantes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."comprobantes"
    ADD CONSTRAINT "comprobantes_storage_path_key" UNIQUE ("storage_path");



ALTER TABLE ONLY "public"."comprobantes"
    ADD CONSTRAINT "comprobantes_un_pago" UNIQUE ("pago_id");



ALTER TABLE ONLY "public"."comprobantes"
    ADD CONSTRAINT "comprobantes_un_pedido" UNIQUE ("pedido_id");



ALTER TABLE ONLY "public"."comunas"
    ADD CONSTRAINT "comunas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."detalles_pedido"
    ADD CONSTRAINT "detalles_pedido_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."direcciones"
    ADD CONSTRAINT "direcciones_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."envios"
    ADD CONSTRAINT "envios_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."generos"
    ADD CONSTRAINT "generos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."generos"
    ADD CONSTRAINT "generos_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."items_carrito"
    ADD CONSTRAINT "items_carrito_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."marcas"
    ADD CONSTRAINT "marcas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."metodos_pago"
    ADD CONSTRAINT "metodos_pago_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pedidos"
    ADD CONSTRAINT "pedidos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."perfiles"
    ADD CONSTRAINT "perfiles_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."perfiles"
    ADD CONSTRAINT "perfiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."perfiles"
    ADD CONSTRAINT "perfiles_rut_key" UNIQUE ("rut");



ALTER TABLE ONLY "public"."productos"
    ADD CONSTRAINT "productos_id_key" UNIQUE ("id");



ALTER TABLE ONLY "public"."productos"
    ADD CONSTRAINT "productos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."regiones"
    ADD CONSTRAINT "regiones_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."stock"
    ADD CONSTRAINT "stock_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."stock"
    ADD CONSTRAINT "unique_producto_talla" UNIQUE ("producto_id", "talla");



CREATE INDEX "comprobante_tareas_pendientes_idx" ON "public"."comprobante_tareas" USING "btree" ("proximo_intento_at", "created_at") WHERE ("estado" = ANY (ARRAY['pendiente'::"text", 'error'::"text", 'procesando'::"text"]));



CREATE UNIQUE INDEX "direcciones_perfil_principal_idx" ON "public"."direcciones" USING "btree" ("perfil_id") WHERE ("es_principal" = true);



CREATE INDEX "productos_genero_id_idx" ON "public"."productos" USING "btree" ("genero_id");



CREATE OR REPLACE TRIGGER "generar-embeddings-al-insertar_productos" AFTER INSERT OR UPDATE ON "public"."productos" FOR EACH ROW EXECUTE FUNCTION "supabase_functions"."http_request"('https://exfoliate-clapping-denim.ngrok-free.dev/api/generate-embeddings', 'POST', '{"x-webhook-secret":"whsec_9a8f7e6d5c4b3a210_supabase_gemini_2026"}', '{}', '5000');



CREATE OR REPLACE TRIGGER "trigger_actualizar_metadata" BEFORE INSERT OR UPDATE ON "public"."productos" FOR EACH ROW EXECUTE FUNCTION "public"."actualizar_metadata_producto"();



CREATE OR REPLACE TRIGGER "trigger_stock_cambio" AFTER INSERT OR DELETE OR UPDATE ON "public"."stock" FOR EACH ROW EXECUTE FUNCTION "public"."recalcular_metadata_por_stock"();



ALTER TABLE ONLY "public"."comprobante_tareas"
    ADD CONSTRAINT "comprobante_tareas_comprobante_id_fkey" FOREIGN KEY ("comprobante_id") REFERENCES "public"."comprobantes"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."comprobantes"
    ADD CONSTRAINT "comprobantes_pedido_id_fkey" FOREIGN KEY ("pedido_id") REFERENCES "public"."pedidos"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."comunas"
    ADD CONSTRAINT "comunas_region_id_fkey" FOREIGN KEY ("region_id") REFERENCES "public"."regiones"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."detalles_pedido"
    ADD CONSTRAINT "detalles_pedido_pedido_id_fkey" FOREIGN KEY ("pedido_id") REFERENCES "public"."pedidos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."detalles_pedido"
    ADD CONSTRAINT "detalles_pedido_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id");



ALTER TABLE ONLY "public"."direcciones"
    ADD CONSTRAINT "direcciones_comuna_id_fkey" FOREIGN KEY ("comuna_id") REFERENCES "public"."comunas"("id");



ALTER TABLE ONLY "public"."direcciones"
    ADD CONSTRAINT "direcciones_perfil_id_fkey" FOREIGN KEY ("perfil_id") REFERENCES "public"."perfiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."direcciones"
    ADD CONSTRAINT "direcciones_region_id_fkey" FOREIGN KEY ("region_id") REFERENCES "public"."regiones"("id");



ALTER TABLE ONLY "public"."envios"
    ADD CONSTRAINT "envios_comuna_id_fkey" FOREIGN KEY ("comuna_id") REFERENCES "public"."comunas"("id");



ALTER TABLE ONLY "public"."envios"
    ADD CONSTRAINT "envios_pedido_id_fkey" FOREIGN KEY ("pedido_id") REFERENCES "public"."pedidos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."envios"
    ADD CONSTRAINT "envios_region_id_fkey" FOREIGN KEY ("region_id") REFERENCES "public"."regiones"("id");



ALTER TABLE ONLY "public"."items_carrito"
    ADD CONSTRAINT "items_carrito_perfil_id_fkey" FOREIGN KEY ("perfil_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."items_carrito"
    ADD CONSTRAINT "items_carrito_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id");



ALTER TABLE ONLY "public"."pedidos"
    ADD CONSTRAINT "pedidos_metodo_pago_id_fkey" FOREIGN KEY ("metodo_pago_id") REFERENCES "public"."metodos_pago"("id");



ALTER TABLE ONLY "public"."pedidos"
    ADD CONSTRAINT "pedidos_perfil_id_fkey" FOREIGN KEY ("perfil_id") REFERENCES "public"."perfiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."perfiles"
    ADD CONSTRAINT "perfiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."productos"
    ADD CONSTRAINT "productos_categoria_id_fkey" FOREIGN KEY ("categoria_id") REFERENCES "public"."categorias"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."productos"
    ADD CONSTRAINT "productos_color_id_fkey" FOREIGN KEY ("color_id") REFERENCES "public"."colores"("id");



ALTER TABLE ONLY "public"."productos"
    ADD CONSTRAINT "productos_genero_id_fkey" FOREIGN KEY ("genero_id") REFERENCES "public"."generos"("id");



ALTER TABLE ONLY "public"."productos"
    ADD CONSTRAINT "productos_marca_id_fkey" FOREIGN KEY ("marca_id") REFERENCES "public"."marcas"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."stock"
    ADD CONSTRAINT "stock_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id") ON DELETE CASCADE;



CREATE POLICY "Lectura pública de comunas" ON "public"."comunas" FOR SELECT USING (true);



CREATE POLICY "Lectura pública de géneros" ON "public"."generos" FOR SELECT USING (true);



CREATE POLICY "Lectura pública de regiones" ON "public"."regiones" FOR SELECT USING (true);



CREATE POLICY "Permitir lectura anonima de detalles_pedido" ON "public"."detalles_pedido" FOR SELECT TO "anon" USING (true);



CREATE POLICY "Permitir lectura anonima de pedidos" ON "public"."pedidos" FOR SELECT TO "anon" USING (true);



CREATE POLICY "Permitir lectura anonima de productos" ON "public"."productos" FOR SELECT TO "anon" USING (true);



CREATE POLICY "Permitir lectura anonima de stock" ON "public"."stock" FOR SELECT TO "anon" USING (true);



CREATE POLICY "Permitir lectura publica de detalles_pedido" ON "public"."detalles_pedido" FOR SELECT TO "anon" USING (true);



CREATE POLICY "Permitir lectura pública de detalles_pedido" ON "public"."detalles_pedido" FOR SELECT USING (true);



CREATE POLICY "Usuarios pueden actualizar su propio perfil" ON "public"."perfiles" FOR UPDATE USING (("auth"."uid"() = "id"));



CREATE POLICY "Usuarios pueden ver su propio perfil" ON "public"."perfiles" FOR SELECT USING (("auth"."uid"() = "id"));



CREATE POLICY "Usuarios ven detalles de sus pedidos" ON "public"."detalles_pedido" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."pedidos" "p"
  WHERE (("p"."id" = "detalles_pedido"."pedido_id") AND ("p"."perfil_id" = ( SELECT "auth"."uid"() AS "uid"))))));



CREATE POLICY "Usuarios ven sus propios pedidos" ON "public"."pedidos" FOR SELECT TO "authenticated" USING (("perfil_id" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."comprobante_tareas" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."comprobantes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."comunas" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."detalles_pedido" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."generos" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "lectura_anon_pedidos" ON "public"."pedidos" FOR SELECT TO "anon" USING (true);



ALTER TABLE "public"."pedidos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."regiones" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;






GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "service_role";











































































































































































GRANT ALL ON FUNCTION "public"."actualizar_metadata_producto"() TO "anon";
GRANT ALL ON FUNCTION "public"."actualizar_metadata_producto"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."actualizar_metadata_producto"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."adquirir_tarea_comprobante"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."adquirir_tarea_comprobante"() TO "service_role";



GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "service_role";



REVOKE ALL ON FUNCTION "public"."crear_pedido_comprobante"("p_perfil_id" "uuid", "p_snapshot" "jsonb", "p_envio" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."crear_pedido_comprobante"("p_perfil_id" "uuid", "p_snapshot" "jsonb", "p_envio" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."fallar_tarea_comprobante"("p_tarea" "uuid", "p_token" "uuid", "p_codigo" "text", "p_revision" boolean, "p_incierto" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fallar_tarea_comprobante"("p_tarea" "uuid", "p_token" "uuid", "p_codigo" "text", "p_revision" boolean, "p_incierto" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."finalizar_tarea_comprobante"("p_tarea" "uuid", "p_token" "uuid", "p_resultado" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."finalizar_tarea_comprobante"("p_tarea" "uuid", "p_token" "uuid", "p_resultado" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "postgres";
GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "anon";
GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "authenticated";
GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "service_role";



GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "postgres";
GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "anon";
GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "authenticated";
GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "service_role";



GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."match_productos"("query_embedding" "public"."vector", "match_count" integer, "filter" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."match_productos"("query_embedding" "public"."vector", "match_count" integer, "filter" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."match_productos"("query_embedding" "public"."vector", "match_count" integer, "filter" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."recalcular_metadata_por_stock"() TO "anon";
GRANT ALL ON FUNCTION "public"."recalcular_metadata_por_stock"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."recalcular_metadata_por_stock"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."registrar_pago_comprobante"("p_pago" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."registrar_pago_comprobante"("p_pago" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."resumen_ventas_dashboard"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."resumen_ventas_dashboard"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "anon";
GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "anon";
GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "service_role";












GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "service_role";



SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;



SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;









GRANT ALL ON TABLE "public"."categorias" TO "anon";
GRANT ALL ON TABLE "public"."categorias" TO "authenticated";
GRANT ALL ON TABLE "public"."categorias" TO "service_role";



GRANT ALL ON SEQUENCE "public"."categorias_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."categorias_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."categorias_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."colores" TO "anon";
GRANT ALL ON TABLE "public"."colores" TO "authenticated";
GRANT ALL ON TABLE "public"."colores" TO "service_role";



GRANT ALL ON SEQUENCE "public"."colores_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."colores_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."colores_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."comprobante_tareas" TO "service_role";



GRANT ALL ON TABLE "public"."comprobantes" TO "service_role";



GRANT ALL ON SEQUENCE "public"."comprobantes_numero_seq" TO "service_role";



GRANT ALL ON TABLE "public"."comunas" TO "anon";
GRANT ALL ON TABLE "public"."comunas" TO "authenticated";
GRANT ALL ON TABLE "public"."comunas" TO "service_role";



GRANT ALL ON SEQUENCE "public"."comunas_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."comunas_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."comunas_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."detalles_pedido" TO "service_role";
GRANT SELECT ON TABLE "public"."detalles_pedido" TO "authenticated";
GRANT SELECT ON TABLE "public"."detalles_pedido" TO "anon";



GRANT ALL ON TABLE "public"."direcciones" TO "anon";
GRANT ALL ON TABLE "public"."direcciones" TO "authenticated";
GRANT ALL ON TABLE "public"."direcciones" TO "service_role";



GRANT ALL ON SEQUENCE "public"."direcciones_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."direcciones_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."direcciones_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."envios" TO "anon";
GRANT ALL ON TABLE "public"."envios" TO "authenticated";
GRANT ALL ON TABLE "public"."envios" TO "service_role";



GRANT ALL ON SEQUENCE "public"."envios_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."envios_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."envios_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."generos" TO "anon";
GRANT ALL ON TABLE "public"."generos" TO "authenticated";
GRANT ALL ON TABLE "public"."generos" TO "service_role";



GRANT ALL ON SEQUENCE "public"."generos_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."generos_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."generos_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."items_carrito" TO "anon";
GRANT ALL ON TABLE "public"."items_carrito" TO "authenticated";
GRANT ALL ON TABLE "public"."items_carrito" TO "service_role";



GRANT ALL ON SEQUENCE "public"."items_carrito_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."items_carrito_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."items_carrito_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."marcas" TO "anon";
GRANT ALL ON TABLE "public"."marcas" TO "authenticated";
GRANT ALL ON TABLE "public"."marcas" TO "service_role";



GRANT ALL ON SEQUENCE "public"."marcas_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."marcas_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."marcas_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."metodos_pago" TO "anon";
GRANT ALL ON TABLE "public"."metodos_pago" TO "authenticated";
GRANT ALL ON TABLE "public"."metodos_pago" TO "service_role";



GRANT ALL ON SEQUENCE "public"."metodos_pago_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."metodos_pago_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."metodos_pago_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."pedidos" TO "service_role";
GRANT SELECT ON TABLE "public"."pedidos" TO "authenticated";
GRANT SELECT ON TABLE "public"."pedidos" TO "anon";



GRANT ALL ON TABLE "public"."perfiles" TO "anon";
GRANT ALL ON TABLE "public"."perfiles" TO "authenticated";
GRANT ALL ON TABLE "public"."perfiles" TO "service_role";



GRANT ALL ON TABLE "public"."productos" TO "anon";
GRANT ALL ON TABLE "public"."productos" TO "authenticated";
GRANT ALL ON TABLE "public"."productos" TO "service_role";



GRANT ALL ON SEQUENCE "public"."productos_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."productos_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."productos_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."regiones" TO "anon";
GRANT ALL ON TABLE "public"."regiones" TO "authenticated";
GRANT ALL ON TABLE "public"."regiones" TO "service_role";



GRANT ALL ON SEQUENCE "public"."regiones_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."regiones_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."regiones_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."stock" TO "anon";
GRANT ALL ON TABLE "public"."stock" TO "authenticated";
GRANT ALL ON TABLE "public"."stock" TO "service_role";



GRANT ALL ON SEQUENCE "public"."stock_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."stock_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."stock_id_seq" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































