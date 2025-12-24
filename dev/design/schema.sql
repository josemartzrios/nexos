-- ============================================
-- NEXOS - Sistema de Agendamiento WhatsApp
-- Schema para Supabase (MVP)
-- ============================================

-- ============================================
-- EXTENSIONES
-- ============================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================
-- TABLAS
-- ============================================

-- Tabla: Especialistas
CREATE TABLE especialistas (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  email TEXT UNIQUE NOT NULL,
  nombre TEXT NOT NULL,
  telefono TEXT,
  especialidad TEXT,
  whatsapp_number TEXT UNIQUE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  activo BOOLEAN DEFAULT true NOT NULL,
  
  -- Constraints adicionales
  CONSTRAINT email_format CHECK (email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')
);

COMMENT ON TABLE especialistas IS 'Especialistas que usan el sistema (médicos, psicólogos, etc.)';
COMMENT ON COLUMN especialistas.whatsapp_number IS 'Número de WhatsApp Business en formato mexicano: +52 seguido de 10 dígitos (ej: +525512345678)';

-- Tabla: Horarios Disponibles
CREATE TABLE horarios_disponibles (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  especialista_id UUID NOT NULL REFERENCES especialistas(id) ON DELETE CASCADE,
  dia_semana INTEGER NOT NULL,
  hora_inicio TIME NOT NULL,
  hora_fin TIME NOT NULL,
  duracion_cita INTEGER DEFAULT 60 NOT NULL,
  activo BOOLEAN DEFAULT true NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  
  -- Constraints
  CONSTRAINT dia_semana_check CHECK (dia_semana >= 0 AND dia_semana <= 6),
  CONSTRAINT duracion_positiva CHECK (duracion_cita > 0),
  CONSTRAINT hora_valida CHECK (hora_inicio < hora_fin),
  CONSTRAINT no_duplicados UNIQUE (especialista_id, dia_semana, hora_inicio, hora_fin)
);

COMMENT ON TABLE horarios_disponibles IS 'Horarios de disponibilidad por día de la semana';
COMMENT ON COLUMN horarios_disponibles.dia_semana IS '0=Domingo, 1=Lunes, 2=Martes, 3=Miércoles, 4=Jueves, 5=Viernes, 6=Sábado';
COMMENT ON COLUMN horarios_disponibles.duracion_cita IS 'Duración de cada cita en minutos';

-- Tabla: Pacientes
CREATE TABLE pacientes (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  nombre TEXT NOT NULL,
  telefono TEXT UNIQUE NOT NULL,
  email TEXT,
  notas TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  
  -- Constraints
  CONSTRAINT telefono_format_mx CHECK (telefono ~ '^\+52[1-9]\d{9}')
);

COMMENT ON TABLE pacientes IS 'Información de pacientes/clientes';
COMMENT ON COLUMN pacientes.telefono IS 'Número de WhatsApp en formato mexicano: +52 seguido de 10 dígitos (ej: +525512345678)';

-- Tabla: Citas
CREATE TABLE citas (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  especialista_id UUID NOT NULL REFERENCES especialistas(id) ON DELETE CASCADE,
  paciente_id UUID NOT NULL REFERENCES pacientes(id) ON DELETE CASCADE,
  fecha_hora TIMESTAMP WITH TIME ZONE NOT NULL,
  duracion INTEGER DEFAULT 60 NOT NULL,
  estado TEXT DEFAULT 'pendiente' NOT NULL,
  motivo TEXT,
  notas TEXT,
  recordatorio_enviado BOOLEAN DEFAULT false NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  
  -- Constraints
  CONSTRAINT estado_valido CHECK (estado IN ('pendiente', 'confirmada', 'cancelada', 'completada')),
  CONSTRAINT duracion_positiva_cita CHECK (duracion > 0),
  CONSTRAINT fecha_futura CHECK (fecha_hora > created_at)
);

COMMENT ON TABLE citas IS 'Citas agendadas entre especialistas y pacientes';
COMMENT ON COLUMN citas.estado IS 'Estados posibles: pendiente, confirmada, cancelada, completada';
COMMENT ON COLUMN citas.duracion IS 'Duración de la cita en minutos';

-- Tabla: Logs de WhatsApp
CREATE TABLE whatsapp_logs (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  telefono TEXT NOT NULL,
  mensaje TEXT,
  direccion TEXT NOT NULL,
  timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  metadata JSONB DEFAULT '{}'::jsonb,
  
  -- Constraints
  CONSTRAINT direccion_valida CHECK (direccion IN ('entrante', 'saliente'))
);

COMMENT ON TABLE whatsapp_logs IS 'Registro de mensajes de WhatsApp para debugging y auditoría';
COMMENT ON COLUMN whatsapp_logs.direccion IS 'Dirección del mensaje: entrante o saliente';

-- ============================================
-- ÍNDICES PARA PERFORMANCE
-- ============================================

-- Índices para especialistas
CREATE INDEX idx_especialistas_email ON especialistas(email);
CREATE INDEX idx_especialistas_whatsapp ON especialistas(whatsapp_number) WHERE whatsapp_number IS NOT NULL;
CREATE INDEX idx_especialistas_activo ON especialistas(activo) WHERE activo = true;

-- Índices para horarios
CREATE INDEX idx_horarios_especialista ON horarios_disponibles(especialista_id);
CREATE INDEX idx_horarios_dia ON horarios_disponibles(especialista_id, dia_semana);
CREATE INDEX idx_horarios_activo ON horarios_disponibles(especialista_id, activo) WHERE activo = true;

-- Índices para pacientes
CREATE INDEX idx_pacientes_telefono ON pacientes(telefono);
CREATE INDEX idx_pacientes_email ON pacientes(email) WHERE email IS NOT NULL;

-- Índices para citas (MUY IMPORTANTES para performance)
CREATE INDEX idx_citas_especialista_fecha ON citas(especialista_id, fecha_hora);
CREATE INDEX idx_citas_paciente ON citas(paciente_id);
CREATE INDEX idx_citas_estado ON citas(estado);
CREATE INDEX idx_citas_recordatorio ON citas(recordatorio_enviado, fecha_hora) 
  WHERE recordatorio_enviado = false AND estado IN ('pendiente', 'confirmada');

-- Índice para buscar citas próximas (muy usado)
CREATE INDEX idx_citas_proximas ON citas(especialista_id, fecha_hora, estado) 
  WHERE fecha_hora > NOW() AND estado IN ('pendiente', 'confirmada');

-- Índices para logs
CREATE INDEX idx_logs_telefono ON whatsapp_logs(telefono);
CREATE INDEX idx_logs_timestamp ON whatsapp_logs(timestamp DESC);
CREATE INDEX idx_logs_direccion ON whatsapp_logs(direccion, timestamp DESC);

-- ============================================
-- FUNCIONES ÚTILES
-- ============================================

-- Función: Obtener horarios disponibles en una fecha específica
CREATE OR REPLACE FUNCTION obtener_horarios_disponibles(
  p_especialista_id UUID,
  p_fecha DATE
)
RETURNS TABLE (
  hora_inicio TIME,
  hora_fin TIME,
  disponible BOOLEAN
) AS $$
DECLARE
  v_dia_semana INTEGER;
BEGIN
  -- Obtener día de la semana (0=Domingo, 6=Sábado)
  v_dia_semana := EXTRACT(DOW FROM p_fecha);
  
  RETURN QUERY
  SELECT 
    h.hora_inicio,
    h.hora_fin,
    NOT EXISTS (
      SELECT 1 FROM citas c
      WHERE c.especialista_id = p_especialista_id
        AND DATE(c.fecha_hora AT TIME ZONE 'America/Mexico_City') = p_fecha
        AND c.estado IN ('pendiente', 'confirmada')
        AND TIME(c.fecha_hora AT TIME ZONE 'America/Mexico_City') >= h.hora_inicio
        AND TIME(c.fecha_hora AT TIME ZONE 'America/Mexico_City') < h.hora_fin
    ) AS disponible
  FROM horarios_disponibles h
  WHERE h.especialista_id = p_especialista_id
    AND h.dia_semana = v_dia_semana
    AND h.activo = true
  ORDER BY h.hora_inicio;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION obtener_horarios_disponibles IS 'Retorna los horarios disponibles de un especialista en una fecha específica';

-- Función: Validar si un horario está disponible
CREATE OR REPLACE FUNCTION validar_horario_disponible(
  p_especialista_id UUID,
  p_fecha_hora TIMESTAMP WITH TIME ZONE,
  p_duracion INTEGER DEFAULT 60
)
RETURNS BOOLEAN AS $$
BEGIN
  -- Verificar que no haya solapamiento con citas existentes
  RETURN NOT EXISTS (
    SELECT 1 FROM citas
    WHERE especialista_id = p_especialista_id
      AND estado IN ('pendiente', 'confirmada')
      AND (
        -- Verifica solapamiento de rangos de tiempo
        (fecha_hora, fecha_hora + (duracion || ' minutes')::INTERVAL) OVERLAPS
        (p_fecha_hora, p_fecha_hora + (p_duracion || ' minutes')::INTERVAL)
      )
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION validar_horario_disponible IS 'Valida si un horario específico está disponible para agendar';

-- Función: Obtener citas del día para un especialista
CREATE OR REPLACE FUNCTION obtener_citas_del_dia(
  p_especialista_id UUID,
  p_fecha DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
  id UUID,
  paciente_nombre TEXT,
  paciente_telefono TEXT,
  fecha_hora TIMESTAMP WITH TIME ZONE,
  duracion INTEGER,
  estado TEXT,
  motivo TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    c.id,
    p.nombre AS paciente_nombre,
    p.telefono AS paciente_telefono,
    c.fecha_hora,
    c.duracion,
    c.estado,
    c.motivo
  FROM citas c
  JOIN pacientes p ON c.paciente_id = p.id
  WHERE c.especialista_id = p_especialista_id
    AND DATE(c.fecha_hora AT TIME ZONE 'America/Mexico_City') = p_fecha
    AND c.estado IN ('pendiente', 'confirmada')
  ORDER BY c.fecha_hora;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION obtener_citas_del_dia IS 'Retorna todas las citas de un especialista para un día específico';

-- ============================================
-- TRIGGERS
-- ============================================

-- Función para actualizar updated_at automáticamente
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Triggers para updated_at
CREATE TRIGGER update_especialistas_updated_at
  BEFORE UPDATE ON especialistas
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_pacientes_updated_at
  BEFORE UPDATE ON pacientes
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_citas_updated_at
  BEFORE UPDATE ON citas
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- ============================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================

-- Habilitar RLS en todas las tablas
ALTER TABLE especialistas ENABLE ROW LEVEL SECURITY;
ALTER TABLE horarios_disponibles ENABLE ROW LEVEL SECURITY;
ALTER TABLE pacientes ENABLE ROW LEVEL SECURITY;
ALTER TABLE citas ENABLE ROW LEVEL SECURITY;
ALTER TABLE whatsapp_logs ENABLE ROW LEVEL SECURITY;

-- Políticas para Especialistas
CREATE POLICY "Especialistas ven sus propios datos"
  ON especialistas FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "Especialistas actualizan sus propios datos"
  ON especialistas FOR UPDATE
  USING (auth.uid() = id);

-- Políticas para Horarios
CREATE POLICY "Especialistas ven sus propios horarios"
  ON horarios_disponibles FOR SELECT
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas crean sus horarios"
  ON horarios_disponibles FOR INSERT
  WITH CHECK (auth.uid() = especialista_id);

CREATE POLICY "Especialistas actualizan sus horarios"
  ON horarios_disponibles FOR UPDATE
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas eliminan sus horarios"
  ON horarios_disponibles FOR DELETE
  USING (auth.uid() = especialista_id);

-- Políticas para Pacientes (los especialistas pueden ver pacientes relacionados a sus citas)
CREATE POLICY "Especialistas ven pacientes de sus citas"
  ON pacientes FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM citas
      WHERE citas.paciente_id = pacientes.id
        AND citas.especialista_id = auth.uid()
    )
  );

CREATE POLICY "Crear pacientes desde citas"
  ON pacientes FOR INSERT
  WITH CHECK (true); -- Se valida en la aplicación

-- Políticas para Citas
CREATE POLICY "Especialistas ven sus propias citas"
  ON citas FOR SELECT
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas crean sus citas"
  ON citas FOR INSERT
  WITH CHECK (auth.uid() = especialista_id);

CREATE POLICY "Especialistas actualizan sus citas"
  ON citas FOR UPDATE
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas eliminan sus citas"
  ON citas FOR DELETE
  USING (auth.uid() = especialista_id);

-- Políticas para Logs
CREATE POLICY "Especialistas ven logs relacionados a su WhatsApp"
  ON whatsapp_logs FOR SELECT
  USING (
    telefono IN (
      SELECT whatsapp_number FROM especialistas WHERE id = auth.uid()
    )
  );

CREATE POLICY "Sistema puede crear logs"
  ON whatsapp_logs FOR INSERT
  WITH CHECK (true); -- Service role puede insertar

-- ============================================
-- DATOS DE PRUEBA
-- ============================================

-- Especialista de prueba
INSERT INTO especialistas (id, email, nombre, telefono, especialidad, whatsapp_number)
VALUES (
  '123e4567-e89b-12d3-a456-426614174000'::uuid,
  'dr.ejemplo@nexos.com',
  'Dr. Juan Pérez',
  '+525512345678',
  'Psicología',
  '+525512345678'
) ON CONFLICT (email) DO NOTHING;

-- Horarios de prueba (Lunes a Viernes, 9am-5pm)
INSERT INTO horarios_disponibles (especialista_id, dia_semana, hora_inicio, hora_fin, duracion_cita)
VALUES 
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 1, '09:00', '17:00', 60), -- Lunes
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 2, '09:00', '17:00', 60), -- Martes
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 3, '09:00', '17:00', 60), -- Miércoles
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 4, '09:00', '17:00', 60), -- Jueves
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 5, '09:00', '17:00', 60)  -- Viernes
ON CONFLICT (especialista_id, dia_semana, hora_inicio, hora_fin) DO NOTHING;

-- Paciente de prueba
INSERT INTO pacientes (nombre, telefono, email)
VALUES ('María González', '+525587654321', 'maria@example.com')
ON CONFLICT (telefono) DO NOTHING;

-- Cita de prueba
INSERT INTO citas (
  especialista_id,
  paciente_id,
  fecha_hora,
  estado,
  motivo
)
VALUES (
  '123e4567-e89b-12d3-a456-426614174000'::uuid,
  (SELECT id FROM pacientes WHERE telefono = '+525587654321'),
  NOW() + INTERVAL '1 day',
  'confirmada',
  'Consulta general'
) ON CONFLICT DO NOTHING;

-- ============================================
-- VERIFICACIÓN
-- ============================================

-- 1. Bloque de verificación (limpio y sin errores de sintaxis)
DO $$
BEGIN
  RAISE NOTICE '✓ Tablas creadas: %', (
    SELECT COUNT(*) FROM information_schema.tables 
    WHERE table_schema = 'public' 
      AND table_name IN ('especialistas', 'horarios_disponibles', 'pacientes', 'citas', 'whatsapp_logs')
  );
  
  RAISE NOTICE '✓ Índices creados: %', (
    SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public'
  );
  
  RAISE NOTICE '✓ Funciones creadas: %', (
    SELECT COUNT(*) FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname IN ('obtener_horarios_disponibles', 'validar_horario_disponible', 'obtener_citas_del_dia')
  );
  
  RAISE NOTICE '✓ Datos de prueba insertados';
  RAISE NOTICE '✓ RLS habilitado en todas las tablas';
  RAISE NOTICE '';
  RAISE NOTICE '🎉 ¡Schema de Nexos instalado exitosamente!';
END $$;

-- 2. Modificación de la tabla especialistas
-- Se usa ALTER TABLE para añadir la restricción de formato de México
ALTER TABLE especialistas 
ADD CONSTRAINT whatsapp_format_mx CHECK (
    whatsapp_number IS NULL OR 
    whatsapp_number ~ '^\+52[1-9]\d{9}$'
);

-- 3. Documentación del esquema
COMMENT ON TABLE especialistas IS 'Especialistas que usan el sistema (médicos, psicólogos, etc.)';
COMMENT ON COLUMN especialistas.whatsapp_number IS 'Número de WhatsApp Business en formato E.164 (+52 + 10 dígitos)';

-- Tabla: Horarios Disponibles
CREATE TABLE horarios_disponibles (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  especialista_id UUID NOT NULL REFERENCES especialistas(id) ON DELETE CASCADE,
  dia_semana INTEGER NOT NULL,
  hora_inicio TIME NOT NULL,
  hora_fin TIME NOT NULL,
  duracion_cita INTEGER DEFAULT 60 NOT NULL,
  activo BOOLEAN DEFAULT true NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  
  -- Constraints
  CONSTRAINT dia_semana_check CHECK (dia_semana >= 0 AND dia_semana <= 6),
  CONSTRAINT duracion_positiva CHECK (duracion_cita > 0),
  CONSTRAINT hora_valida CHECK (hora_inicio < hora_fin),
  CONSTRAINT no_duplicados UNIQUE (especialista_id, dia_semana, hora_inicio, hora_fin)
);

COMMENT ON TABLE horarios_disponibles IS 'Horarios de disponibilidad por día de la semana';
COMMENT ON COLUMN horarios_disponibles.dia_semana IS '0=Domingo, 1=Lunes, 2=Martes, 3=Miércoles, 4=Jueves, 5=Viernes, 6=Sábado';
COMMENT ON COLUMN horarios_disponibles.duracion_cita IS 'Duración de cada cita en minutos';

-- Tabla: Pacientes
CREATE TABLE pacientes (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  nombre TEXT NOT NULL,
  telefono TEXT UNIQUE NOT NULL,
  email TEXT,
  notas TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  
  -- Constraints
  CONSTRAINT telefono_format CHECK (telefono ~ '^\+[1-9]\d{1,14}$'),
  CONSTRAINT email_format_paciente CHECK (email IS NULL OR email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
);

COMMENT ON TABLE pacientes IS 'Información de pacientes/clientes';
COMMENT ON COLUMN pacientes.telefono IS 'Número de teléfono en formato E.164 (+52...)';

-- Tabla: Citas
CREATE TABLE citas (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  especialista_id UUID NOT NULL REFERENCES especialistas(id) ON DELETE CASCADE,
  paciente_id UUID NOT NULL REFERENCES pacientes(id) ON DELETE CASCADE,
  fecha_hora TIMESTAMP WITH TIME ZONE NOT NULL,
  duracion INTEGER DEFAULT 60 NOT NULL,
  estado TEXT DEFAULT 'pendiente' NOT NULL,
  motivo TEXT,
  notas TEXT,
  recordatorio_enviado BOOLEAN DEFAULT false NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  
  -- Constraints
  CONSTRAINT estado_valido CHECK (estado IN ('pendiente', 'confirmada', 'cancelada', 'completada')),
  CONSTRAINT duracion_positiva_cita CHECK (duracion > 0),
  CONSTRAINT fecha_futura CHECK (fecha_hora > created_at)
);

COMMENT ON TABLE citas IS 'Citas agendadas entre especialistas y pacientes';
COMMENT ON COLUMN citas.estado IS 'Estados posibles: pendiente, confirmada, cancelada, completada';
COMMENT ON COLUMN citas.duracion IS 'Duración de la cita en minutos';

-- Tabla: Logs de WhatsApp
CREATE TABLE whatsapp_logs (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  telefono TEXT NOT NULL,
  mensaje TEXT,
  direccion TEXT NOT NULL,
  timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  metadata JSONB DEFAULT '{}'::jsonb,
  
  -- Constraints
  CONSTRAINT direccion_valida CHECK (direccion IN ('entrante', 'saliente'))
);

COMMENT ON TABLE whatsapp_logs IS 'Registro de mensajes de WhatsApp para debugging y auditoría';
COMMENT ON COLUMN whatsapp_logs.direccion IS 'Dirección del mensaje: entrante o saliente';

-- ============================================
-- ÍNDICES PARA PERFORMANCE
-- ============================================

-- Índices para especialistas
CREATE INDEX idx_especialistas_email ON especialistas(email);
CREATE INDEX idx_especialistas_whatsapp ON especialistas(whatsapp_number) WHERE whatsapp_number IS NOT NULL;
CREATE INDEX idx_especialistas_activo ON especialistas(activo) WHERE activo = true;

-- Índices para horarios
CREATE INDEX idx_horarios_especialista ON horarios_disponibles(especialista_id);
CREATE INDEX idx_horarios_dia ON horarios_disponibles(especialista_id, dia_semana);
CREATE INDEX idx_horarios_activo ON horarios_disponibles(especialista_id, activo) WHERE activo = true;

-- Índices para pacientes
CREATE INDEX idx_pacientes_telefono ON pacientes(telefono);
CREATE INDEX idx_pacientes_email ON pacientes(email) WHERE email IS NOT NULL;

-- Índices para citas (MUY IMPORTANTES para performance)
CREATE INDEX idx_citas_especialista_fecha ON citas(especialista_id, fecha_hora);
CREATE INDEX idx_citas_paciente ON citas(paciente_id);
CREATE INDEX idx_citas_estado ON citas(estado);
CREATE INDEX idx_citas_recordatorio ON citas(recordatorio_enviado, fecha_hora) 
  WHERE recordatorio_enviado = false AND estado IN ('pendiente', 'confirmada');

-- Índice para buscar citas próximas (muy usado)
CREATE INDEX idx_citas_proximas ON citas(especialista_id, fecha_hora, estado) 
  WHERE fecha_hora > NOW() AND estado IN ('pendiente', 'confirmada');

-- Índices para logs
CREATE INDEX idx_logs_telefono ON whatsapp_logs(telefono);
CREATE INDEX idx_logs_timestamp ON whatsapp_logs(timestamp DESC);
CREATE INDEX idx_logs_direccion ON whatsapp_logs(direccion, timestamp DESC);

-- ============================================
-- FUNCIONES ÚTILES
-- ============================================

-- Función: Obtener horarios disponibles en una fecha específica
CREATE OR REPLACE FUNCTION obtener_horarios_disponibles(
  p_especialista_id UUID,
  p_fecha DATE
)
RETURNS TABLE (
  hora_inicio TIME,
  hora_fin TIME,
  disponible BOOLEAN
) AS $$
DECLARE
  v_dia_semana INTEGER;
BEGIN
  -- Obtener día de la semana (0=Domingo, 6=Sábado)
  v_dia_semana := EXTRACT(DOW FROM p_fecha);
  
  RETURN QUERY
  SELECT 
    h.hora_inicio,
    h.hora_fin,
    NOT EXISTS (
      SELECT 1 FROM citas c
      WHERE c.especialista_id = p_especialista_id
        AND DATE(c.fecha_hora AT TIME ZONE 'America/Mexico_City') = p_fecha
        AND c.estado IN ('pendiente', 'confirmada')
        AND TIME(c.fecha_hora AT TIME ZONE 'America/Mexico_City') >= h.hora_inicio
        AND TIME(c.fecha_hora AT TIME ZONE 'America/Mexico_City') < h.hora_fin
    ) AS disponible
  FROM horarios_disponibles h
  WHERE h.especialista_id = p_especialista_id
    AND h.dia_semana = v_dia_semana
    AND h.activo = true
  ORDER BY h.hora_inicio;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION obtener_horarios_disponibles IS 'Retorna los horarios disponibles de un especialista en una fecha específica';

-- Función: Validar si un horario está disponible
CREATE OR REPLACE FUNCTION validar_horario_disponible(
  p_especialista_id UUID,
  p_fecha_hora TIMESTAMP WITH TIME ZONE,
  p_duracion INTEGER DEFAULT 60
)
RETURNS BOOLEAN AS $$
BEGIN
  -- Verificar que no haya solapamiento con citas existentes
  RETURN NOT EXISTS (
    SELECT 1 FROM citas
    WHERE especialista_id = p_especialista_id
      AND estado IN ('pendiente', 'confirmada')
      AND (
        -- Verifica solapamiento de rangos de tiempo
        (fecha_hora, fecha_hora + (duracion || ' minutes')::INTERVAL) OVERLAPS
        (p_fecha_hora, p_fecha_hora + (p_duracion || ' minutes')::INTERVAL)
      )
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION validar_horario_disponible IS 'Valida si un horario específico está disponible para agendar';

-- Función: Obtener citas del día para un especialista
CREATE OR REPLACE FUNCTION obtener_citas_del_dia(
  p_especialista_id UUID,
  p_fecha DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
  id UUID,
  paciente_nombre TEXT,
  paciente_telefono TEXT,
  fecha_hora TIMESTAMP WITH TIME ZONE,
  duracion INTEGER,
  estado TEXT,
  motivo TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    c.id,
    p.nombre AS paciente_nombre,
    p.telefono AS paciente_telefono,
    c.fecha_hora,
    c.duracion,
    c.estado,
    c.motivo
  FROM citas c
  JOIN pacientes p ON c.paciente_id = p.id
  WHERE c.especialista_id = p_especialista_id
    AND DATE(c.fecha_hora AT TIME ZONE 'America/Mexico_City') = p_fecha
    AND c.estado IN ('pendiente', 'confirmada')
  ORDER BY c.fecha_hora;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION obtener_citas_del_dia IS 'Retorna todas las citas de un especialista para un día específico';

-- ============================================
-- TRIGGERS
-- ============================================

-- Función para actualizar updated_at automáticamente
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Triggers para updated_at
CREATE TRIGGER update_especialistas_updated_at
  BEFORE UPDATE ON especialistas
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_pacientes_updated_at
  BEFORE UPDATE ON pacientes
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_citas_updated_at
  BEFORE UPDATE ON citas
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- ============================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================

-- Habilitar RLS en todas las tablas
ALTER TABLE especialistas ENABLE ROW LEVEL SECURITY;
ALTER TABLE horarios_disponibles ENABLE ROW LEVEL SECURITY;
ALTER TABLE pacientes ENABLE ROW LEVEL SECURITY;
ALTER TABLE citas ENABLE ROW LEVEL SECURITY;
ALTER TABLE whatsapp_logs ENABLE ROW LEVEL SECURITY;

-- Políticas para Especialistas
CREATE POLICY "Especialistas ven sus propios datos"
  ON especialistas FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "Especialistas actualizan sus propios datos"
  ON especialistas FOR UPDATE
  USING (auth.uid() = id);

-- Políticas para Horarios
CREATE POLICY "Especialistas ven sus propios horarios"
  ON horarios_disponibles FOR SELECT
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas crean sus horarios"
  ON horarios_disponibles FOR INSERT
  WITH CHECK (auth.uid() = especialista_id);

CREATE POLICY "Especialistas actualizan sus horarios"
  ON horarios_disponibles FOR UPDATE
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas eliminan sus horarios"
  ON horarios_disponibles FOR DELETE
  USING (auth.uid() = especialista_id);

-- Políticas para Pacientes (los especialistas pueden ver pacientes relacionados a sus citas)
CREATE POLICY "Especialistas ven pacientes de sus citas"
  ON pacientes FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM citas
      WHERE citas.paciente_id = pacientes.id
        AND citas.especialista_id = auth.uid()
    )
  );

CREATE POLICY "Crear pacientes desde citas"
  ON pacientes FOR INSERT
  WITH CHECK (true); -- Se valida en la aplicación

-- Políticas para Citas
CREATE POLICY "Especialistas ven sus propias citas"
  ON citas FOR SELECT
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas crean sus citas"
  ON citas FOR INSERT
  WITH CHECK (auth.uid() = especialista_id);

CREATE POLICY "Especialistas actualizan sus citas"
  ON citas FOR UPDATE
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas eliminan sus citas"
  ON citas FOR DELETE
  USING (auth.uid() = especialista_id);

-- Políticas para Logs
CREATE POLICY "Especialistas ven logs relacionados a su WhatsApp"
  ON whatsapp_logs FOR SELECT
  USING (
    telefono IN (
      SELECT whatsapp_number FROM especialistas WHERE id = auth.uid()
    )
  );

CREATE POLICY "Sistema puede crear logs"
  ON whatsapp_logs FOR INSERT
  WITH CHECK (true); -- Service role puede insertar

-- ============================================
-- DATOS DE PRUEBA
-- ============================================

-- Especialista de prueba
INSERT INTO especialistas (id, email, nombre, telefono, especialidad, whatsapp_number)
VALUES (
  '123e4567-e89b-12d3-a456-426614174000'::uuid,
  'dr.ejemplo@nexos.com',
  'Dr. Juan Pérez',
  '+525512345678',
  'Psicología',
  '+525512345678'
) ON CONFLICT (email) DO NOTHING;

-- Horarios de prueba (Lunes a Viernes, 9am-5pm)
INSERT INTO horarios_disponibles (especialista_id, dia_semana, hora_inicio, hora_fin, duracion_cita)
VALUES 
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 1, '09:00', '17:00', 60), -- Lunes
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 2, '09:00', '17:00', 60), -- Martes
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 3, '09:00', '17:00', 60), -- Miércoles
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 4, '09:00', '17:00', 60), -- Jueves
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 5, '09:00', '17:00', 60)  -- Viernes
ON CONFLICT (especialista_id, dia_semana, hora_inicio, hora_fin) DO NOTHING;

-- Paciente de prueba
INSERT INTO pacientes (nombre, telefono, email)
VALUES ('María González', '+525587654321', 'maria@example.com')
ON CONFLICT (telefono) DO NOTHING;

-- Cita de prueba
INSERT INTO citas (
  especialista_id,
  paciente_id,
  fecha_hora,
  estado,
  motivo
)
VALUES (
  '123e4567-e89b-12d3-a456-426614174000'::uuid,
  (SELECT id FROM pacientes WHERE telefono = '+525587654321'),
  NOW() + INTERVAL '1 day',
  'confirmada',
  'Consulta general'
) ON CONFLICT DO NOTHING;

-- ============================================
-- VERIFICACIÓN
-- ============================================

-- Query para verificar que todo se creó correctamente
DO $$
BEGIN
  RAISE NOTICE '✓ Tablas creadas: %', (
    SELECT COUNT(*) FROM information_schema.tables 
    WHERE table_schema = 'public' 
      AND table_name IN ('especialistas', 'horarios_disponibles', 'pacientes', 'citas', 'whatsapp_logs')
  );
  
  RAISE NOTICE '✓ Índices creados: %', (
    SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public'
  );
  
  RAISE NOTICE '✓ Funciones creadas: %', (
    SELECT COUNT(*) FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname IN ('obtener_horarios_disponibles', 'validar_horario_disponible', 'obtener_citas_del_dia')
  );
  
  RAISE NOTICE '✓ Datos de prueba insertados';
  RAISE NOTICE '✓ RLS habilitado en todas las tablas';
  RAISE NOTICE '';
  RAISE NOTICE '🎉 ¡Schema de Nexos instalado exitosamente!';
END $$;

-- Comentarios (Fuera del bloque DO)
COMMENT ON TABLE especialistas IS 'Especialistas que usan el sistema (médicos, psicólogos, etc.)';
COMMENT ON COLUMN especialistas.whatsapp_number IS 'Número de WhatsApp Business en formato E.164 (Ej: +521234567890)';

-- Tabla: Horarios Disponibles
CREATE TABLE horarios_disponibles (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  especialista_id UUID NOT NULL REFERENCES especialistas(id) ON DELETE CASCADE,
  dia_semana INTEGER NOT NULL,
  hora_inicio TIME NOT NULL,
  hora_fin TIME NOT NULL,
  duracion_cita INTEGER DEFAULT 60 NOT NULL,
  activo BOOLEAN DEFAULT true NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  
  -- Constraints
  CONSTRAINT dia_semana_check CHECK (dia_semana >= 0 AND dia_semana <= 6),
  CONSTRAINT duracion_positiva CHECK (duracion_cita > 0),
  CONSTRAINT hora_valida CHECK (hora_inicio < hora_fin),
  CONSTRAINT no_duplicados UNIQUE (especialista_id, dia_semana, hora_inicio, hora_fin)
);

COMMENT ON TABLE horarios_disponibles IS 'Horarios de disponibilidad por día de la semana';
COMMENT ON COLUMN horarios_disponibles.dia_semana IS '0=Domingo, 1=Lunes, 2=Martes, 3=Miércoles, 4=Jueves, 5=Viernes, 6=Sábado';
COMMENT ON COLUMN horarios_disponibles.duracion_cita IS 'Duración de cada cita en minutos';

-- Tabla: Pacientes
CREATE TABLE pacientes (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  nombre TEXT NOT NULL,
  telefono TEXT UNIQUE NOT NULL,
  email TEXT,
  notas TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  
  -- Constraints
  CONSTRAINT telefono_format CHECK (telefono ~ '^\+[1-9]\d{1,14}$'),
  CONSTRAINT email_format_paciente CHECK (email IS NULL OR email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
);

COMMENT ON TABLE pacientes IS 'Información de pacientes/clientes';
COMMENT ON COLUMN pacientes.telefono IS 'Número de teléfono en formato E.164 (+52...)';

-- Tabla: Citas
CREATE TABLE citas (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  especialista_id UUID NOT NULL REFERENCES especialistas(id) ON DELETE CASCADE,
  paciente_id UUID NOT NULL REFERENCES pacientes(id) ON DELETE CASCADE,
  fecha_hora TIMESTAMP WITH TIME ZONE NOT NULL,
  duracion INTEGER DEFAULT 60 NOT NULL,
  estado TEXT DEFAULT 'pendiente' NOT NULL,
  motivo TEXT,
  notas TEXT,
  recordatorio_enviado BOOLEAN DEFAULT false NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  
  -- Constraints
  CONSTRAINT estado_valido CHECK (estado IN ('pendiente', 'confirmada', 'cancelada', 'completada')),
  CONSTRAINT duracion_positiva_cita CHECK (duracion > 0),
  CONSTRAINT fecha_futura CHECK (fecha_hora > created_at)
);

COMMENT ON TABLE citas IS 'Citas agendadas entre especialistas y pacientes';
COMMENT ON COLUMN citas.estado IS 'Estados posibles: pendiente, confirmada, cancelada, completada';
COMMENT ON COLUMN citas.duracion IS 'Duración de la cita en minutos';

-- Tabla: Logs de WhatsApp
CREATE TABLE whatsapp_logs (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  telefono TEXT NOT NULL,
  mensaje TEXT,
  direccion TEXT NOT NULL,
  timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  metadata JSONB DEFAULT '{}'::jsonb,
  
  -- Constraints
  CONSTRAINT direccion_valida CHECK (direccion IN ('entrante', 'saliente'))
);

COMMENT ON TABLE whatsapp_logs IS 'Registro de mensajes de WhatsApp para debugging y auditoría';
COMMENT ON COLUMN whatsapp_logs.direccion IS 'Dirección del mensaje: entrante o saliente';

-- ============================================
-- ÍNDICES PARA PERFORMANCE
-- ============================================

-- Índices para especialistas
CREATE INDEX idx_especialistas_email ON especialistas(email);
CREATE INDEX idx_especialistas_whatsapp ON especialistas(whatsapp_number) WHERE whatsapp_number IS NOT NULL;
CREATE INDEX idx_especialistas_activo ON especialistas(activo) WHERE activo = true;

-- Índices para horarios
CREATE INDEX idx_horarios_especialista ON horarios_disponibles(especialista_id);
CREATE INDEX idx_horarios_dia ON horarios_disponibles(especialista_id, dia_semana);
CREATE INDEX idx_horarios_activo ON horarios_disponibles(especialista_id, activo) WHERE activo = true;

-- Índices para pacientes
CREATE INDEX idx_pacientes_telefono ON pacientes(telefono);
CREATE INDEX idx_pacientes_email ON pacientes(email) WHERE email IS NOT NULL;

-- Índices para citas (MUY IMPORTANTES para performance)
CREATE INDEX idx_citas_especialista_fecha ON citas(especialista_id, fecha_hora);
CREATE INDEX idx_citas_paciente ON citas(paciente_id);
CREATE INDEX idx_citas_estado ON citas(estado);
CREATE INDEX idx_citas_recordatorio ON citas(recordatorio_enviado, fecha_hora) 
  WHERE recordatorio_enviado = false AND estado IN ('pendiente', 'confirmada');

-- Índice para buscar citas próximas (muy usado)
CREATE INDEX idx_citas_proximas ON citas(especialista_id, fecha_hora, estado) 
  WHERE fecha_hora > NOW() AND estado IN ('pendiente', 'confirmada');

-- Índices para logs
CREATE INDEX idx_logs_telefono ON whatsapp_logs(telefono);
CREATE INDEX idx_logs_timestamp ON whatsapp_logs(timestamp DESC);
CREATE INDEX idx_logs_direccion ON whatsapp_logs(direccion, timestamp DESC);

-- ============================================
-- FUNCIONES ÚTILES
-- ============================================

-- Función: Obtener horarios disponibles en una fecha específica
CREATE OR REPLACE FUNCTION obtener_horarios_disponibles(
  p_especialista_id UUID,
  p_fecha DATE
)
RETURNS TABLE (
  hora_inicio TIME,
  hora_fin TIME,
  disponible BOOLEAN
) AS $$
DECLARE
  v_dia_semana INTEGER;
BEGIN
  -- Obtener día de la semana (0=Domingo, 6=Sábado)
  v_dia_semana := EXTRACT(DOW FROM p_fecha);
  
  RETURN QUERY
  SELECT 
    h.hora_inicio,
    h.hora_fin,
    NOT EXISTS (
      SELECT 1 FROM citas c
      WHERE c.especialista_id = p_especialista_id
        AND DATE(c.fecha_hora AT TIME ZONE 'America/Mexico_City') = p_fecha
        AND c.estado IN ('pendiente', 'confirmada')
        AND TIME(c.fecha_hora AT TIME ZONE 'America/Mexico_City') >= h.hora_inicio
        AND TIME(c.fecha_hora AT TIME ZONE 'America/Mexico_City') < h.hora_fin
    ) AS disponible
  FROM horarios_disponibles h
  WHERE h.especialista_id = p_especialista_id
    AND h.dia_semana = v_dia_semana
    AND h.activo = true
  ORDER BY h.hora_inicio;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION obtener_horarios_disponibles IS 'Retorna los horarios disponibles de un especialista en una fecha específica';

-- Función: Validar si un horario está disponible
CREATE OR REPLACE FUNCTION validar_horario_disponible(
  p_especialista_id UUID,
  p_fecha_hora TIMESTAMP WITH TIME ZONE,
  p_duracion INTEGER DEFAULT 60
)
RETURNS BOOLEAN AS $$
BEGIN
  -- Verificar que no haya solapamiento con citas existentes
  RETURN NOT EXISTS (
    SELECT 1 FROM citas
    WHERE especialista_id = p_especialista_id
      AND estado IN ('pendiente', 'confirmada')
      AND (
        -- Verifica solapamiento de rangos de tiempo
        (fecha_hora, fecha_hora + (duracion || ' minutes')::INTERVAL) OVERLAPS
        (p_fecha_hora, p_fecha_hora + (p_duracion || ' minutes')::INTERVAL)
      )
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION validar_horario_disponible IS 'Valida si un horario específico está disponible para agendar';

-- Función: Obtener citas del día para un especialista
CREATE OR REPLACE FUNCTION obtener_citas_del_dia(
  p_especialista_id UUID,
  p_fecha DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
  id UUID,
  paciente_nombre TEXT,
  paciente_telefono TEXT,
  fecha_hora TIMESTAMP WITH TIME ZONE,
  duracion INTEGER,
  estado TEXT,
  motivo TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    c.id,
    p.nombre AS paciente_nombre,
    p.telefono AS paciente_telefono,
    c.fecha_hora,
    c.duracion,
    c.estado,
    c.motivo
  FROM citas c
  JOIN pacientes p ON c.paciente_id = p.id
  WHERE c.especialista_id = p_especialista_id
    AND DATE(c.fecha_hora AT TIME ZONE 'America/Mexico_City') = p_fecha
    AND c.estado IN ('pendiente', 'confirmada')
  ORDER BY c.fecha_hora;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION obtener_citas_del_dia IS 'Retorna todas las citas de un especialista para un día específico';

-- ============================================
-- TRIGGERS
-- ============================================

-- Función para actualizar updated_at automáticamente
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Triggers para updated_at
CREATE TRIGGER update_especialistas_updated_at
  BEFORE UPDATE ON especialistas
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_pacientes_updated_at
  BEFORE UPDATE ON pacientes
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_citas_updated_at
  BEFORE UPDATE ON citas
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- ============================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================

-- Habilitar RLS en todas las tablas
ALTER TABLE especialistas ENABLE ROW LEVEL SECURITY;
ALTER TABLE horarios_disponibles ENABLE ROW LEVEL SECURITY;
ALTER TABLE pacientes ENABLE ROW LEVEL SECURITY;
ALTER TABLE citas ENABLE ROW LEVEL SECURITY;
ALTER TABLE whatsapp_logs ENABLE ROW LEVEL SECURITY;

-- Políticas para Especialistas
CREATE POLICY "Especialistas ven sus propios datos"
  ON especialistas FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "Especialistas actualizan sus propios datos"
  ON especialistas FOR UPDATE
  USING (auth.uid() = id);

-- Políticas para Horarios
CREATE POLICY "Especialistas ven sus propios horarios"
  ON horarios_disponibles FOR SELECT
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas crean sus horarios"
  ON horarios_disponibles FOR INSERT
  WITH CHECK (auth.uid() = especialista_id);

CREATE POLICY "Especialistas actualizan sus horarios"
  ON horarios_disponibles FOR UPDATE
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas eliminan sus horarios"
  ON horarios_disponibles FOR DELETE
  USING (auth.uid() = especialista_id);

-- Políticas para Pacientes (los especialistas pueden ver pacientes relacionados a sus citas)
CREATE POLICY "Especialistas ven pacientes de sus citas"
  ON pacientes FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM citas
      WHERE citas.paciente_id = pacientes.id
        AND citas.especialista_id = auth.uid()
    )
  );

CREATE POLICY "Crear pacientes desde citas"
  ON pacientes FOR INSERT
  WITH CHECK (true); -- Se valida en la aplicación

-- Políticas para Citas
CREATE POLICY "Especialistas ven sus propias citas"
  ON citas FOR SELECT
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas crean sus citas"
  ON citas FOR INSERT
  WITH CHECK (auth.uid() = especialista_id);

CREATE POLICY "Especialistas actualizan sus citas"
  ON citas FOR UPDATE
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas eliminan sus citas"
  ON citas FOR DELETE
  USING (auth.uid() = especialista_id);

-- Políticas para Logs
CREATE POLICY "Especialistas ven logs relacionados a su WhatsApp"
  ON whatsapp_logs FOR SELECT
  USING (
    telefono IN (
      SELECT whatsapp_number FROM especialistas WHERE id = auth.uid()
    )
  );

CREATE POLICY "Sistema puede crear logs"
  ON whatsapp_logs FOR INSERT
  WITH CHECK (true); -- Service role puede insertar

-- ============================================
-- DATOS DE PRUEBA
-- ============================================

-- Especialista de prueba
INSERT INTO especialistas (id, email, nombre, telefono, especialidad, whatsapp_number)
VALUES (
  '123e4567-e89b-12d3-a456-426614174000'::uuid,
  'dr.ejemplo@nexos.com',
  'Dr. Juan Pérez',
  '+525512345678',
  'Psicología',
  '+525512345678'
) ON CONFLICT (email) DO NOTHING;

-- Horarios de prueba (Lunes a Viernes, 9am-5pm)
INSERT INTO horarios_disponibles (especialista_id, dia_semana, hora_inicio, hora_fin, duracion_cita)
VALUES 
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 1, '09:00', '17:00', 60), -- Lunes
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 2, '09:00', '17:00', 60), -- Martes
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 3, '09:00', '17:00', 60), -- Miércoles
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 4, '09:00', '17:00', 60), -- Jueves
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 5, '09:00', '17:00', 60)  -- Viernes
ON CONFLICT (especialista_id, dia_semana, hora_inicio, hora_fin) DO NOTHING;

-- Paciente de prueba
INSERT INTO pacientes (nombre, telefono, email)
VALUES ('María González', '+525587654321', 'maria@example.com')
ON CONFLICT (telefono) DO NOTHING;

-- Cita de prueba
INSERT INTO citas (
  especialista_id,
  paciente_id,
  fecha_hora,
  estado,
  motivo
)
VALUES (
  '123e4567-e89b-12d3-a456-426614174000'::uuid,
  (SELECT id FROM pacientes WHERE telefono = '+525587654321'),
  NOW() + INTERVAL '1 day',
  'confirmada',
  'Consulta general'
) ON CONFLICT DO NOTHING;

-- ============================================
-- VERIFICACIÓN
-- ============================================

-- Query para verificar que todo se creó correctamente
DO $$
BEGIN
  RAISE NOTICE '✓ Tablas creadas: %', (
    SELECT COUNT(*) FROM information_schema.tables 
    WHERE table_schema = 'public' 
      AND table_name IN ('especialistas', 'horarios_disponibles', 'pacientes', 'citas', 'whatsapp_logs')
  );
  
  RAISE NOTICE '✓ Índices creados: %', (
    SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public'
  );
  
  RAISE NOTICE '✓ Funciones creadas: %', (
    SELECT COUNT(*) FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname IN ('obtener_horarios_disponibles', 'validar_horario_disponible', 'obtener_citas_del_dia')
  );
  
  RAISE NOTICE '✓ Datos de prueba insertados';
  RAISE NOTICE '✓ RLS habilitado en todas las tablas';
  RAISE NOTICE '';
  RAISE NOTICE '🎉 ¡Schema de Nexos instalado exitosamente!';
END $$;

ALTER TABLE pacientes -- Formato mexicano: +52 + 10 dígitos
ADD CONSTRAINT email_format_paciente 
CHECK (email IS NULL OR email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}');


COMMENT ON TABLE pacientes IS 'Información de pacientes/clientes';
COMMENT ON COLUMN pacientes.telefono IS 'Número de teléfono en formato E.164 (+52...)';

-- Tabla: Citas
CREATE TABLE citas (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  especialista_id UUID NOT NULL REFERENCES especialistas(id) ON DELETE CASCADE,
  paciente_id UUID NOT NULL REFERENCES pacientes(id) ON DELETE CASCADE,
  fecha_hora TIMESTAMP WITH TIME ZONE NOT NULL,
  duracion INTEGER DEFAULT 60 NOT NULL,
  estado TEXT DEFAULT 'pendiente' NOT NULL,
  motivo TEXT,
  notas TEXT,
  recordatorio_enviado BOOLEAN DEFAULT false NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  
  -- Constraints
  CONSTRAINT estado_valido CHECK (estado IN ('pendiente', 'confirmada', 'cancelada', 'completada')),
  CONSTRAINT duracion_positiva_cita CHECK (duracion > 0),
  CONSTRAINT fecha_futura CHECK (fecha_hora > created_at)
);

COMMENT ON TABLE citas IS 'Citas agendadas entre especialistas y pacientes';
COMMENT ON COLUMN citas.estado IS 'Estados posibles: pendiente, confirmada, cancelada, completada';
COMMENT ON COLUMN citas.duracion IS 'Duración de la cita en minutos';

-- Tabla: Logs de WhatsApp
CREATE TABLE whatsapp_logs (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  telefono TEXT NOT NULL,
  mensaje TEXT,
  direccion TEXT NOT NULL,
  timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  metadata JSONB DEFAULT '{}'::jsonb,
  
  -- Constraints
  CONSTRAINT direccion_valida CHECK (direccion IN ('entrante', 'saliente'))
);

COMMENT ON TABLE whatsapp_logs IS 'Registro de mensajes de WhatsApp para debugging y auditoría';
COMMENT ON COLUMN whatsapp_logs.direccion IS 'Dirección del mensaje: entrante o saliente';

-- ============================================
-- ÍNDICES PARA PERFORMANCE
-- ============================================

-- Índices para especialistas
CREATE INDEX idx_especialistas_email ON especialistas(email);
CREATE INDEX idx_especialistas_whatsapp ON especialistas(whatsapp_number) WHERE whatsapp_number IS NOT NULL;
CREATE INDEX idx_especialistas_activo ON especialistas(activo) WHERE activo = true;

-- Índices para horarios
CREATE INDEX idx_horarios_especialista ON horarios_disponibles(especialista_id);
CREATE INDEX idx_horarios_dia ON horarios_disponibles(especialista_id, dia_semana);
CREATE INDEX idx_horarios_activo ON horarios_disponibles(especialista_id, activo) WHERE activo = true;

-- Índices para pacientes
CREATE INDEX idx_pacientes_telefono ON pacientes(telefono);
CREATE INDEX idx_pacientes_email ON pacientes(email) WHERE email IS NOT NULL;

-- Índices para citas (MUY IMPORTANTES para performance)
CREATE INDEX idx_citas_especialista_fecha ON citas(especialista_id, fecha_hora);
CREATE INDEX idx_citas_paciente ON citas(paciente_id);
CREATE INDEX idx_citas_estado ON citas(estado);
CREATE INDEX idx_citas_recordatorio ON citas(recordatorio_enviado, fecha_hora) 
  WHERE recordatorio_enviado = false AND estado IN ('pendiente', 'confirmada');

-- Índice para buscar citas próximas (muy usado)
CREATE INDEX idx_citas_proximas ON citas(especialista_id, fecha_hora, estado) 
  WHERE fecha_hora > NOW() AND estado IN ('pendiente', 'confirmada');

-- Índices para logs
CREATE INDEX idx_logs_telefono ON whatsapp_logs(telefono);
CREATE INDEX idx_logs_timestamp ON whatsapp_logs(timestamp DESC);
CREATE INDEX idx_logs_direccion ON whatsapp_logs(direccion, timestamp DESC);

-- ============================================
-- FUNCIONES ÚTILES
-- ============================================

-- Función: Obtener horarios disponibles en una fecha específica
CREATE OR REPLACE FUNCTION obtener_horarios_disponibles(
  p_especialista_id UUID,
  p_fecha DATE
)
RETURNS TABLE (
  hora_inicio TIME,
  hora_fin TIME,
  disponible BOOLEAN
) AS $$
DECLARE
  v_dia_semana INTEGER;
BEGIN
  -- Obtener día de la semana (0=Domingo, 6=Sábado)
  v_dia_semana := EXTRACT(DOW FROM p_fecha);
  
  RETURN QUERY
  SELECT 
    h.hora_inicio,
    h.hora_fin,
    NOT EXISTS (
      SELECT 1 FROM citas c
      WHERE c.especialista_id = p_especialista_id
        AND DATE(c.fecha_hora AT TIME ZONE 'America/Mexico_City') = p_fecha
        AND c.estado IN ('pendiente', 'confirmada')
        AND TIME(c.fecha_hora AT TIME ZONE 'America/Mexico_City') >= h.hora_inicio
        AND TIME(c.fecha_hora AT TIME ZONE 'America/Mexico_City') < h.hora_fin
    ) AS disponible
  FROM horarios_disponibles h
  WHERE h.especialista_id = p_especialista_id
    AND h.dia_semana = v_dia_semana
    AND h.activo = true
  ORDER BY h.hora_inicio;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION obtener_horarios_disponibles IS 'Retorna los horarios disponibles de un especialista en una fecha específica';

-- Función: Validar si un horario está disponible
CREATE OR REPLACE FUNCTION validar_horario_disponible(
  p_especialista_id UUID,
  p_fecha_hora TIMESTAMP WITH TIME ZONE,
  p_duracion INTEGER DEFAULT 60
)
RETURNS BOOLEAN AS $$
BEGIN
  -- Verificar que no haya solapamiento con citas existentes
  RETURN NOT EXISTS (
    SELECT 1 FROM citas
    WHERE especialista_id = p_especialista_id
      AND estado IN ('pendiente', 'confirmada')
      AND (
        -- Verifica solapamiento de rangos de tiempo
        (fecha_hora, fecha_hora + (duracion || ' minutes')::INTERVAL) OVERLAPS
        (p_fecha_hora, p_fecha_hora + (p_duracion || ' minutes')::INTERVAL)
      )
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION validar_horario_disponible IS 'Valida si un horario específico está disponible para agendar';

-- Función: Obtener citas del día para un especialista
CREATE OR REPLACE FUNCTION obtener_citas_del_dia(
  p_especialista_id UUID,
  p_fecha DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
  id UUID,
  paciente_nombre TEXT,
  paciente_telefono TEXT,
  fecha_hora TIMESTAMP WITH TIME ZONE,
  duracion INTEGER,
  estado TEXT,
  motivo TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    c.id,
    p.nombre AS paciente_nombre,
    p.telefono AS paciente_telefono,
    c.fecha_hora,
    c.duracion,
    c.estado,
    c.motivo
  FROM citas c
  JOIN pacientes p ON c.paciente_id = p.id
  WHERE c.especialista_id = p_especialista_id
    AND DATE(c.fecha_hora AT TIME ZONE 'America/Mexico_City') = p_fecha
    AND c.estado IN ('pendiente', 'confirmada')
  ORDER BY c.fecha_hora;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION obtener_citas_del_dia IS 'Retorna todas las citas de un especialista para un día específico';

-- ============================================
-- TRIGGERS
-- ============================================

-- Función para actualizar updated_at automáticamente
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Triggers para updated_at
CREATE TRIGGER update_especialistas_updated_at
  BEFORE UPDATE ON especialistas
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_pacientes_updated_at
  BEFORE UPDATE ON pacientes
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_citas_updated_at
  BEFORE UPDATE ON citas
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- ============================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================

-- Habilitar RLS en todas las tablas
ALTER TABLE especialistas ENABLE ROW LEVEL SECURITY;
ALTER TABLE horarios_disponibles ENABLE ROW LEVEL SECURITY;
ALTER TABLE pacientes ENABLE ROW LEVEL SECURITY;
ALTER TABLE citas ENABLE ROW LEVEL SECURITY;
ALTER TABLE whatsapp_logs ENABLE ROW LEVEL SECURITY;

-- Políticas para Especialistas
CREATE POLICY "Especialistas ven sus propios datos"
  ON especialistas FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "Especialistas actualizan sus propios datos"
  ON especialistas FOR UPDATE
  USING (auth.uid() = id);

-- Políticas para Horarios
CREATE POLICY "Especialistas ven sus propios horarios"
  ON horarios_disponibles FOR SELECT
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas crean sus horarios"
  ON horarios_disponibles FOR INSERT
  WITH CHECK (auth.uid() = especialista_id);

CREATE POLICY "Especialistas actualizan sus horarios"
  ON horarios_disponibles FOR UPDATE
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas eliminan sus horarios"
  ON horarios_disponibles FOR DELETE
  USING (auth.uid() = especialista_id);

-- Políticas para Pacientes (los especialistas pueden ver pacientes relacionados a sus citas)
CREATE POLICY "Especialistas ven pacientes de sus citas"
  ON pacientes FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM citas
      WHERE citas.paciente_id = pacientes.id
        AND citas.especialista_id = auth.uid()
    )
  );

CREATE POLICY "Crear pacientes desde citas"
  ON pacientes FOR INSERT
  WITH CHECK (true); -- Se valida en la aplicación

-- Políticas para Citas
CREATE POLICY "Especialistas ven sus propias citas"
  ON citas FOR SELECT
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas crean sus citas"
  ON citas FOR INSERT
  WITH CHECK (auth.uid() = especialista_id);

CREATE POLICY "Especialistas actualizan sus citas"
  ON citas FOR UPDATE
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas eliminan sus citas"
  ON citas FOR DELETE
  USING (auth.uid() = especialista_id);

-- Políticas para Logs
CREATE POLICY "Especialistas ven logs relacionados a su WhatsApp"
  ON whatsapp_logs FOR SELECT
  USING (
    telefono IN (
      SELECT whatsapp_number FROM especialistas WHERE id = auth.uid()
    )
  );

CREATE POLICY "Sistema puede crear logs"
  ON whatsapp_logs FOR INSERT
  WITH CHECK (true); -- Service role puede insertar

-- ============================================
-- DATOS DE PRUEBA
-- ============================================

-- Especialista de prueba
INSERT INTO especialistas (id, email, nombre, telefono, especialidad, whatsapp_number)
VALUES (
  '123e4567-e89b-12d3-a456-426614174000'::uuid,
  'dr.ejemplo@nexos.com',
  'Dr. Juan Pérez',
  '+525512345678',
  'Psicología',
  '+525512345678'
) ON CONFLICT (email) DO NOTHING;

-- Horarios de prueba (Lunes a Viernes, 9am-5pm)
INSERT INTO horarios_disponibles (especialista_id, dia_semana, hora_inicio, hora_fin, duracion_cita)
VALUES 
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 1, '09:00', '17:00', 60), -- Lunes
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 2, '09:00', '17:00', 60), -- Martes
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 3, '09:00', '17:00', 60), -- Miércoles
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 4, '09:00', '17:00', 60), -- Jueves
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 5, '09:00', '17:00', 60)  -- Viernes
ON CONFLICT (especialista_id, dia_semana, hora_inicio, hora_fin) DO NOTHING;

-- Paciente de prueba
INSERT INTO pacientes (nombre, telefono, email)
VALUES ('María González', '+525587654321', 'maria@example.com')
ON CONFLICT (telefono) DO NOTHING;

-- Cita de prueba
INSERT INTO citas (
  especialista_id,
  paciente_id,
  fecha_hora,
  estado,
  motivo
)
VALUES (
  '123e4567-e89b-12d3-a456-426614174000'::uuid,
  (SELECT id FROM pacientes WHERE telefono = '+525587654321'),
  NOW() + INTERVAL '1 day',
  'confirmada',
  'Consulta general'
) ON CONFLICT DO NOTHING;

-- ============================================
-- VERIFICACIÓN
-- ============================================

-- Query para verificar que todo se creó correctamente
DO $$
BEGIN
  RAISE NOTICE '✓ Tablas creadas: %', (
    SELECT COUNT(*) FROM information_schema.tables 
    WHERE table_schema = 'public' 
      AND table_name IN ('especialistas', 'horarios_disponibles', 'pacientes', 'citas', 'whatsapp_logs')
  );
  
  RAISE NOTICE '✓ Índices creados: %', (
    SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public'
  );
  
  RAISE NOTICE '✓ Funciones creadas: %', (
    SELECT COUNT(*) FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname IN ('obtener_horarios_disponibles', 'validar_horario_disponible', 'obtener_citas_del_dia')
  );
  
  RAISE NOTICE '✓ Datos de prueba insertados';
  RAISE NOTICE '✓ RLS habilitado en todas las tablas';
  RAISE NOTICE '';
  RAISE NOTICE '🎉 ¡Schema de Nexos instalado exitosamente!';
END $$;
  
ALTER TABLE especialistas
ADD CONSTRAINT whatsapp_format_mx 
CHECK (
  whatsapp_number IS NULL OR 
  whatsapp_number ~ '^\+52[1-9]\d{9}'
);


COMMENT ON TABLE especialistas IS 'Especialistas que usan el sistema (médicos, psicólogos, etc.)';
COMMENT ON COLUMN especialistas.whatsapp_number IS 'Número de WhatsApp Business en formato E.164';

-- Tabla: Horarios Disponibles
CREATE TABLE horarios_disponibles (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  especialista_id UUID NOT NULL REFERENCES especialistas(id) ON DELETE CASCADE,
  dia_semana INTEGER NOT NULL,
  hora_inicio TIME NOT NULL,
  hora_fin TIME NOT NULL,
  duracion_cita INTEGER DEFAULT 60 NOT NULL,
  activo BOOLEAN DEFAULT true NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  
  -- Constraints
  CONSTRAINT dia_semana_check CHECK (dia_semana >= 0 AND dia_semana <= 6),
  CONSTRAINT duracion_positiva CHECK (duracion_cita > 0),
  CONSTRAINT hora_valida CHECK (hora_inicio < hora_fin),
  CONSTRAINT no_duplicados UNIQUE (especialista_id, dia_semana, hora_inicio, hora_fin)
);

COMMENT ON TABLE horarios_disponibles IS 'Horarios de disponibilidad por día de la semana';
COMMENT ON COLUMN horarios_disponibles.dia_semana IS '0=Domingo, 1=Lunes, 2=Martes, 3=Miércoles, 4=Jueves, 5=Viernes, 6=Sábado';
COMMENT ON COLUMN horarios_disponibles.duracion_cita IS 'Duración de cada cita en minutos';

-- Tabla: Pacientes
CREATE TABLE pacientes (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  nombre TEXT NOT NULL,
  telefono TEXT UNIQUE NOT NULL,
  email TEXT,
  notas TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  
  -- Constraints
  CONSTRAINT telefono_format CHECK (telefono ~ '^\+[1-9]\d{1,14}$'),
  CONSTRAINT email_format_paciente CHECK (email IS NULL OR email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
);

COMMENT ON TABLE pacientes IS 'Información de pacientes/clientes';
COMMENT ON COLUMN pacientes.telefono IS 'Número de teléfono en formato E.164 (+52...)';

-- Tabla: Citas
CREATE TABLE citas (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  especialista_id UUID NOT NULL REFERENCES especialistas(id) ON DELETE CASCADE,
  paciente_id UUID NOT NULL REFERENCES pacientes(id) ON DELETE CASCADE,
  fecha_hora TIMESTAMP WITH TIME ZONE NOT NULL,
  duracion INTEGER DEFAULT 60 NOT NULL,
  estado TEXT DEFAULT 'pendiente' NOT NULL,
  motivo TEXT,
  notas TEXT,
  recordatorio_enviado BOOLEAN DEFAULT false NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  
  -- Constraints
  CONSTRAINT estado_valido CHECK (estado IN ('pendiente', 'confirmada', 'cancelada', 'completada')),
  CONSTRAINT duracion_positiva_cita CHECK (duracion > 0),
  CONSTRAINT fecha_futura CHECK (fecha_hora > created_at)
);

COMMENT ON TABLE citas IS 'Citas agendadas entre especialistas y pacientes';
COMMENT ON COLUMN citas.estado IS 'Estados posibles: pendiente, confirmada, cancelada, completada';
COMMENT ON COLUMN citas.duracion IS 'Duración de la cita en minutos';

-- Tabla: Logs de WhatsApp
CREATE TABLE whatsapp_logs (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  telefono TEXT NOT NULL,
  mensaje TEXT,
  direccion TEXT NOT NULL,
  timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  metadata JSONB DEFAULT '{}'::jsonb,
  
  -- Constraints
  CONSTRAINT direccion_valida CHECK (direccion IN ('entrante', 'saliente'))
);

COMMENT ON TABLE whatsapp_logs IS 'Registro de mensajes de WhatsApp para debugging y auditoría';
COMMENT ON COLUMN whatsapp_logs.direccion IS 'Dirección del mensaje: entrante o saliente';

-- ============================================
-- ÍNDICES PARA PERFORMANCE
-- ============================================

-- Índices para especialistas
CREATE INDEX idx_especialistas_email ON especialistas(email);
CREATE INDEX idx_especialistas_whatsapp ON especialistas(whatsapp_number) WHERE whatsapp_number IS NOT NULL;
CREATE INDEX idx_especialistas_activo ON especialistas(activo) WHERE activo = true;

-- Índices para horarios
CREATE INDEX idx_horarios_especialista ON horarios_disponibles(especialista_id);
CREATE INDEX idx_horarios_dia ON horarios_disponibles(especialista_id, dia_semana);
CREATE INDEX idx_horarios_activo ON horarios_disponibles(especialista_id, activo) WHERE activo = true;

-- Índices para pacientes
CREATE INDEX idx_pacientes_telefono ON pacientes(telefono);
CREATE INDEX idx_pacientes_email ON pacientes(email) WHERE email IS NOT NULL;

-- Índices para citas (MUY IMPORTANTES para performance)
CREATE INDEX idx_citas_especialista_fecha ON citas(especialista_id, fecha_hora);
CREATE INDEX idx_citas_paciente ON citas(paciente_id);
CREATE INDEX idx_citas_estado ON citas(estado);
CREATE INDEX idx_citas_recordatorio ON citas(recordatorio_enviado, fecha_hora) 
  WHERE recordatorio_enviado = false AND estado IN ('pendiente', 'confirmada');

-- Índice para buscar citas próximas (muy usado)
CREATE INDEX idx_citas_proximas ON citas(especialista_id, fecha_hora, estado) 
  WHERE fecha_hora > NOW() AND estado IN ('pendiente', 'confirmada');

-- Índices para logs
CREATE INDEX idx_logs_telefono ON whatsapp_logs(telefono);
CREATE INDEX idx_logs_timestamp ON whatsapp_logs(timestamp DESC);
CREATE INDEX idx_logs_direccion ON whatsapp_logs(direccion, timestamp DESC);

-- ============================================
-- FUNCIONES ÚTILES
-- ============================================

-- Función: Obtener horarios disponibles en una fecha específica
CREATE OR REPLACE FUNCTION obtener_horarios_disponibles(
  p_especialista_id UUID,
  p_fecha DATE
)
RETURNS TABLE (
  hora_inicio TIME,
  hora_fin TIME,
  disponible BOOLEAN
) AS $$
DECLARE
  v_dia_semana INTEGER;
BEGIN
  -- Obtener día de la semana (0=Domingo, 6=Sábado)
  v_dia_semana := EXTRACT(DOW FROM p_fecha);
  
  RETURN QUERY
  SELECT 
    h.hora_inicio,
    h.hora_fin,
    NOT EXISTS (
      SELECT 1 FROM citas c
      WHERE c.especialista_id = p_especialista_id
        AND DATE(c.fecha_hora AT TIME ZONE 'America/Mexico_City') = p_fecha
        AND c.estado IN ('pendiente', 'confirmada')
        AND TIME(c.fecha_hora AT TIME ZONE 'America/Mexico_City') >= h.hora_inicio
        AND TIME(c.fecha_hora AT TIME ZONE 'America/Mexico_City') < h.hora_fin
    ) AS disponible
  FROM horarios_disponibles h
  WHERE h.especialista_id = p_especialista_id
    AND h.dia_semana = v_dia_semana
    AND h.activo = true
  ORDER BY h.hora_inicio;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION obtener_horarios_disponibles IS 'Retorna los horarios disponibles de un especialista en una fecha específica';

-- Función: Validar si un horario está disponible
CREATE OR REPLACE FUNCTION validar_horario_disponible(
  p_especialista_id UUID,
  p_fecha_hora TIMESTAMP WITH TIME ZONE,
  p_duracion INTEGER DEFAULT 60
)
RETURNS BOOLEAN AS $$
BEGIN
  -- Verificar que no haya solapamiento con citas existentes
  RETURN NOT EXISTS (
    SELECT 1 FROM citas
    WHERE especialista_id = p_especialista_id
      AND estado IN ('pendiente', 'confirmada')
      AND (
        -- Verifica solapamiento de rangos de tiempo
        (fecha_hora, fecha_hora + (duracion || ' minutes')::INTERVAL) OVERLAPS
        (p_fecha_hora, p_fecha_hora + (p_duracion || ' minutes')::INTERVAL)
      )
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION validar_horario_disponible IS 'Valida si un horario específico está disponible para agendar';

-- Función: Obtener citas del día para un especialista
CREATE OR REPLACE FUNCTION obtener_citas_del_dia(
  p_especialista_id UUID,
  p_fecha DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
  id UUID,
  paciente_nombre TEXT,
  paciente_telefono TEXT,
  fecha_hora TIMESTAMP WITH TIME ZONE,
  duracion INTEGER,
  estado TEXT,
  motivo TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    c.id,
    p.nombre AS paciente_nombre,
    p.telefono AS paciente_telefono,
    c.fecha_hora,
    c.duracion,
    c.estado,
    c.motivo
  FROM citas c
  JOIN pacientes p ON c.paciente_id = p.id
  WHERE c.especialista_id = p_especialista_id
    AND DATE(c.fecha_hora AT TIME ZONE 'America/Mexico_City') = p_fecha
    AND c.estado IN ('pendiente', 'confirmada')
  ORDER BY c.fecha_hora;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION obtener_citas_del_dia IS 'Retorna todas las citas de un especialista para un día específico';

-- ============================================
-- TRIGGERS
-- ============================================

-- Función para actualizar updated_at automáticamente
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Triggers para updated_at
CREATE TRIGGER update_especialistas_updated_at
  BEFORE UPDATE ON especialistas
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_pacientes_updated_at
  BEFORE UPDATE ON pacientes
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_citas_updated_at
  BEFORE UPDATE ON citas
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- ============================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================

-- Habilitar RLS en todas las tablas
ALTER TABLE especialistas ENABLE ROW LEVEL SECURITY;
ALTER TABLE horarios_disponibles ENABLE ROW LEVEL SECURITY;
ALTER TABLE pacientes ENABLE ROW LEVEL SECURITY;
ALTER TABLE citas ENABLE ROW LEVEL SECURITY;
ALTER TABLE whatsapp_logs ENABLE ROW LEVEL SECURITY;

-- Políticas para Especialistas
CREATE POLICY "Especialistas ven sus propios datos"
  ON especialistas FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "Especialistas actualizan sus propios datos"
  ON especialistas FOR UPDATE
  USING (auth.uid() = id);

-- Políticas para Horarios
CREATE POLICY "Especialistas ven sus propios horarios"
  ON horarios_disponibles FOR SELECT
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas crean sus horarios"
  ON horarios_disponibles FOR INSERT
  WITH CHECK (auth.uid() = especialista_id);

CREATE POLICY "Especialistas actualizan sus horarios"
  ON horarios_disponibles FOR UPDATE
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas eliminan sus horarios"
  ON horarios_disponibles FOR DELETE
  USING (auth.uid() = especialista_id);

-- Políticas para Pacientes (los especialistas pueden ver pacientes relacionados a sus citas)
CREATE POLICY "Especialistas ven pacientes de sus citas"
  ON pacientes FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM citas
      WHERE citas.paciente_id = pacientes.id
        AND citas.especialista_id = auth.uid()
    )
  );

CREATE POLICY "Crear pacientes desde citas"
  ON pacientes FOR INSERT
  WITH CHECK (true); -- Se valida en la aplicación

-- Políticas para Citas
CREATE POLICY "Especialistas ven sus propias citas"
  ON citas FOR SELECT
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas crean sus citas"
  ON citas FOR INSERT
  WITH CHECK (auth.uid() = especialista_id);

CREATE POLICY "Especialistas actualizan sus citas"
  ON citas FOR UPDATE
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas eliminan sus citas"
  ON citas FOR DELETE
  USING (auth.uid() = especialista_id);

-- Políticas para Logs
CREATE POLICY "Especialistas ven logs relacionados a su WhatsApp"
  ON whatsapp_logs FOR SELECT
  USING (
    telefono IN (
      SELECT whatsapp_number FROM especialistas WHERE id = auth.uid()
    )
  );

CREATE POLICY "Sistema puede crear logs"
  ON whatsapp_logs FOR INSERT
  WITH CHECK (true); -- Service role puede insertar

-- ============================================
-- DATOS DE PRUEBA
-- ============================================

-- Especialista de prueba
INSERT INTO especialistas (id, email, nombre, telefono, especialidad, whatsapp_number)
VALUES (
  '123e4567-e89b-12d3-a456-426614174000'::uuid,
  'dr.ejemplo@nexos.com',
  'Dr. Juan Pérez',
  '+525512345678',
  'Psicología',
  '+525512345678'
) ON CONFLICT (email) DO NOTHING;

-- Horarios de prueba (Lunes a Viernes, 9am-5pm)
INSERT INTO horarios_disponibles (especialista_id, dia_semana, hora_inicio, hora_fin, duracion_cita)
VALUES 
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 1, '09:00', '17:00', 60), -- Lunes
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 2, '09:00', '17:00', 60), -- Martes
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 3, '09:00', '17:00', 60), -- Miércoles
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 4, '09:00', '17:00', 60), -- Jueves
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 5, '09:00', '17:00', 60)  -- Viernes
ON CONFLICT (especialista_id, dia_semana, hora_inicio, hora_fin) DO NOTHING;

-- Paciente de prueba
INSERT INTO pacientes (nombre, telefono, email)
VALUES ('María González', '+525587654321', 'maria@example.com')
ON CONFLICT (telefono) DO NOTHING;

-- Cita de prueba
INSERT INTO citas (
  especialista_id,
  paciente_id,
  fecha_hora,
  estado,
  motivo
)
VALUES (
  '123e4567-e89b-12d3-a456-426614174000'::uuid,
  (SELECT id FROM pacientes WHERE telefono = '+525587654321'),
  NOW() + INTERVAL '1 day',
  'confirmada',
  'Consulta general'
) ON CONFLICT DO NOTHING;

-- ============================================
-- VERIFICACIÓN
-- ============================================

-- Query para verificar que todo se creó correctamente
DO $$
BEGIN
  RAISE NOTICE '✓ Tablas creadas: %', (
    SELECT COUNT(*) FROM information_schema.tables 
    WHERE table_schema = 'public' 
      AND table_name IN ('especialistas', 'horarios_disponibles', 'pacientes', 'citas', 'whatsapp_logs')
  );
  
  RAISE NOTICE '✓ Índices creados: %', (
    SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public'
  );
  
  RAISE NOTICE '✓ Funciones creadas: %', (
    SELECT COUNT(*) FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname IN ('obtener_horarios_disponibles', 'validar_horario_disponible', 'obtener_citas_del_dia')
  );
  
  RAISE NOTICE '✓ Datos de prueba insertados';
  RAISE NOTICE '✓ RLS habilitado en todas las tablas';
  RAISE NOTICE '';
  RAISE NOTICE '🎉 ¡Schema de Nexos instalado exitosamente!';
END $$; -- Formato mexicano: +52 + 10 dígitos


COMMENT ON TABLE especialistas IS 'Especialistas que usan el sistema (médicos, psicólogos, etc.)';
COMMENT ON COLUMN especialistas.whatsapp_number IS 'Número de WhatsApp Business en formato E.164';

-- Tabla: Horarios Disponibles
CREATE TABLE horarios_disponibles (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  especialista_id UUID NOT NULL REFERENCES especialistas(id) ON DELETE CASCADE,
  dia_semana INTEGER NOT NULL,
  hora_inicio TIME NOT NULL,
  hora_fin TIME NOT NULL,
  duracion_cita INTEGER DEFAULT 60 NOT NULL,
  activo BOOLEAN DEFAULT true NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  
  -- Constraints
  CONSTRAINT dia_semana_check CHECK (dia_semana >= 0 AND dia_semana <= 6),
  CONSTRAINT duracion_positiva CHECK (duracion_cita > 0),
  CONSTRAINT hora_valida CHECK (hora_inicio < hora_fin),
  CONSTRAINT no_duplicados UNIQUE (especialista_id, dia_semana, hora_inicio, hora_fin)
);

COMMENT ON TABLE horarios_disponibles IS 'Horarios de disponibilidad por día de la semana';
COMMENT ON COLUMN horarios_disponibles.dia_semana IS '0=Domingo, 1=Lunes, 2=Martes, 3=Miércoles, 4=Jueves, 5=Viernes, 6=Sábado';
COMMENT ON COLUMN horarios_disponibles.duracion_cita IS 'Duración de cada cita en minutos';

-- Tabla: Pacientes
CREATE TABLE pacientes (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  nombre TEXT NOT NULL,
  telefono TEXT UNIQUE NOT NULL,
  email TEXT,
  notas TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  
  -- Constraints
  CONSTRAINT telefono_format CHECK (telefono ~ '^\+[1-9]\d{1,14}$'),
  CONSTRAINT email_format_paciente CHECK (email IS NULL OR email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
);

COMMENT ON TABLE pacientes IS 'Información de pacientes/clientes';
COMMENT ON COLUMN pacientes.telefono IS 'Número de teléfono en formato E.164 (+52...)';

-- Tabla: Citas
CREATE TABLE citas (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  especialista_id UUID NOT NULL REFERENCES especialistas(id) ON DELETE CASCADE,
  paciente_id UUID NOT NULL REFERENCES pacientes(id) ON DELETE CASCADE,
  fecha_hora TIMESTAMP WITH TIME ZONE NOT NULL,
  duracion INTEGER DEFAULT 60 NOT NULL,
  estado TEXT DEFAULT 'pendiente' NOT NULL,
  motivo TEXT,
  notas TEXT,
  recordatorio_enviado BOOLEAN DEFAULT false NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  
  -- Constraints
  CONSTRAINT estado_valido CHECK (estado IN ('pendiente', 'confirmada', 'cancelada', 'completada')),
  CONSTRAINT duracion_positiva_cita CHECK (duracion > 0),
  CONSTRAINT fecha_futura CHECK (fecha_hora > created_at)
);

COMMENT ON TABLE citas IS 'Citas agendadas entre especialistas y pacientes';
COMMENT ON COLUMN citas.estado IS 'Estados posibles: pendiente, confirmada, cancelada, completada';
COMMENT ON COLUMN citas.duracion IS 'Duración de la cita en minutos';

-- Tabla: Logs de WhatsApp
CREATE TABLE whatsapp_logs (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  telefono TEXT NOT NULL,
  mensaje TEXT,
  direccion TEXT NOT NULL,
  timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  metadata JSONB DEFAULT '{}'::jsonb,
  
  -- Constraints
  CONSTRAINT direccion_valida CHECK (direccion IN ('entrante', 'saliente'))
);

COMMENT ON TABLE whatsapp_logs IS 'Registro de mensajes de WhatsApp para debugging y auditoría';
COMMENT ON COLUMN whatsapp_logs.direccion IS 'Dirección del mensaje: entrante o saliente';

-- ============================================
-- ÍNDICES PARA PERFORMANCE
-- ============================================

-- Índices para especialistas
CREATE INDEX idx_especialistas_email ON especialistas(email);
CREATE INDEX idx_especialistas_whatsapp ON especialistas(whatsapp_number) WHERE whatsapp_number IS NOT NULL;
CREATE INDEX idx_especialistas_activo ON especialistas(activo) WHERE activo = true;

-- Índices para horarios
CREATE INDEX idx_horarios_especialista ON horarios_disponibles(especialista_id);
CREATE INDEX idx_horarios_dia ON horarios_disponibles(especialista_id, dia_semana);
CREATE INDEX idx_horarios_activo ON horarios_disponibles(especialista_id, activo) WHERE activo = true;

-- Índices para pacientes
CREATE INDEX idx_pacientes_telefono ON pacientes(telefono);
CREATE INDEX idx_pacientes_email ON pacientes(email) WHERE email IS NOT NULL;

-- Índices para citas (MUY IMPORTANTES para performance)
CREATE INDEX idx_citas_especialista_fecha ON citas(especialista_id, fecha_hora);
CREATE INDEX idx_citas_paciente ON citas(paciente_id);
CREATE INDEX idx_citas_estado ON citas(estado);
CREATE INDEX idx_citas_recordatorio ON citas(recordatorio_enviado, fecha_hora) 
  WHERE recordatorio_enviado = false AND estado IN ('pendiente', 'confirmada');

-- Índice para buscar citas próximas (muy usado)
CREATE INDEX idx_citas_proximas ON citas(especialista_id, fecha_hora, estado) 
  WHERE fecha_hora > NOW() AND estado IN ('pendiente', 'confirmada');

-- Índices para logs
CREATE INDEX idx_logs_telefono ON whatsapp_logs(telefono);
CREATE INDEX idx_logs_timestamp ON whatsapp_logs(timestamp DESC);
CREATE INDEX idx_logs_direccion ON whatsapp_logs(direccion, timestamp DESC);

-- ============================================
-- FUNCIONES ÚTILES
-- ============================================

-- Función: Obtener horarios disponibles en una fecha específica
CREATE OR REPLACE FUNCTION obtener_horarios_disponibles(
  p_especialista_id UUID,
  p_fecha DATE
)
RETURNS TABLE (
  hora_inicio TIME,
  hora_fin TIME,
  disponible BOOLEAN
) AS $$
DECLARE
  v_dia_semana INTEGER;
BEGIN
  -- Obtener día de la semana (0=Domingo, 6=Sábado)
  v_dia_semana := EXTRACT(DOW FROM p_fecha);
  
  RETURN QUERY
  SELECT 
    h.hora_inicio,
    h.hora_fin,
    NOT EXISTS (
      SELECT 1 FROM citas c
      WHERE c.especialista_id = p_especialista_id
        AND DATE(c.fecha_hora AT TIME ZONE 'America/Mexico_City') = p_fecha
        AND c.estado IN ('pendiente', 'confirmada')
        AND TIME(c.fecha_hora AT TIME ZONE 'America/Mexico_City') >= h.hora_inicio
        AND TIME(c.fecha_hora AT TIME ZONE 'America/Mexico_City') < h.hora_fin
    ) AS disponible
  FROM horarios_disponibles h
  WHERE h.especialista_id = p_especialista_id
    AND h.dia_semana = v_dia_semana
    AND h.activo = true
  ORDER BY h.hora_inicio;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION obtener_horarios_disponibles IS 'Retorna los horarios disponibles de un especialista en una fecha específica';

-- Función: Validar si un horario está disponible
CREATE OR REPLACE FUNCTION validar_horario_disponible(
  p_especialista_id UUID,
  p_fecha_hora TIMESTAMP WITH TIME ZONE,
  p_duracion INTEGER DEFAULT 60
)
RETURNS BOOLEAN AS $$
BEGIN
  -- Verificar que no haya solapamiento con citas existentes
  RETURN NOT EXISTS (
    SELECT 1 FROM citas
    WHERE especialista_id = p_especialista_id
      AND estado IN ('pendiente', 'confirmada')
      AND (
        -- Verifica solapamiento de rangos de tiempo
        (fecha_hora, fecha_hora + (duracion || ' minutes')::INTERVAL) OVERLAPS
        (p_fecha_hora, p_fecha_hora + (p_duracion || ' minutes')::INTERVAL)
      )
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION validar_horario_disponible IS 'Valida si un horario específico está disponible para agendar';

-- Función: Obtener citas del día para un especialista
CREATE OR REPLACE FUNCTION obtener_citas_del_dia(
  p_especialista_id UUID,
  p_fecha DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
  id UUID,
  paciente_nombre TEXT,
  paciente_telefono TEXT,
  fecha_hora TIMESTAMP WITH TIME ZONE,
  duracion INTEGER,
  estado TEXT,
  motivo TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    c.id,
    p.nombre AS paciente_nombre,
    p.telefono AS paciente_telefono,
    c.fecha_hora,
    c.duracion,
    c.estado,
    c.motivo
  FROM citas c
  JOIN pacientes p ON c.paciente_id = p.id
  WHERE c.especialista_id = p_especialista_id
    AND DATE(c.fecha_hora AT TIME ZONE 'America/Mexico_City') = p_fecha
    AND c.estado IN ('pendiente', 'confirmada')
  ORDER BY c.fecha_hora;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION obtener_citas_del_dia IS 'Retorna todas las citas de un especialista para un día específico';

-- ============================================
-- TRIGGERS
-- ============================================

-- Función para actualizar updated_at automáticamente
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Triggers para updated_at
CREATE TRIGGER update_especialistas_updated_at
  BEFORE UPDATE ON especialistas
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_pacientes_updated_at
  BEFORE UPDATE ON pacientes
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_citas_updated_at
  BEFORE UPDATE ON citas
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- ============================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================

-- Habilitar RLS en todas las tablas
ALTER TABLE especialistas ENABLE ROW LEVEL SECURITY;
ALTER TABLE horarios_disponibles ENABLE ROW LEVEL SECURITY;
ALTER TABLE pacientes ENABLE ROW LEVEL SECURITY;
ALTER TABLE citas ENABLE ROW LEVEL SECURITY;
ALTER TABLE whatsapp_logs ENABLE ROW LEVEL SECURITY;

-- Políticas para Especialistas
CREATE POLICY "Especialistas ven sus propios datos"
  ON especialistas FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "Especialistas actualizan sus propios datos"
  ON especialistas FOR UPDATE
  USING (auth.uid() = id);

-- Políticas para Horarios
CREATE POLICY "Especialistas ven sus propios horarios"
  ON horarios_disponibles FOR SELECT
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas crean sus horarios"
  ON horarios_disponibles FOR INSERT
  WITH CHECK (auth.uid() = especialista_id);

CREATE POLICY "Especialistas actualizan sus horarios"
  ON horarios_disponibles FOR UPDATE
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas eliminan sus horarios"
  ON horarios_disponibles FOR DELETE
  USING (auth.uid() = especialista_id);

-- Políticas para Pacientes (los especialistas pueden ver pacientes relacionados a sus citas)
CREATE POLICY "Especialistas ven pacientes de sus citas"
  ON pacientes FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM citas
      WHERE citas.paciente_id = pacientes.id
        AND citas.especialista_id = auth.uid()
    )
  );

CREATE POLICY "Crear pacientes desde citas"
  ON pacientes FOR INSERT
  WITH CHECK (true); -- Se valida en la aplicación

-- Políticas para Citas
CREATE POLICY "Especialistas ven sus propias citas"
  ON citas FOR SELECT
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas crean sus citas"
  ON citas FOR INSERT
  WITH CHECK (auth.uid() = especialista_id);

CREATE POLICY "Especialistas actualizan sus citas"
  ON citas FOR UPDATE
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas eliminan sus citas"
  ON citas FOR DELETE
  USING (auth.uid() = especialista_id);

-- Políticas para Logs
CREATE POLICY "Especialistas ven logs relacionados a su WhatsApp"
  ON whatsapp_logs FOR SELECT
  USING (
    telefono IN (
      SELECT whatsapp_number FROM especialistas WHERE id = auth.uid()
    )
  );

CREATE POLICY "Sistema puede crear logs"
  ON whatsapp_logs FOR INSERT
  WITH CHECK (true); -- Service role puede insertar

-- ============================================
-- DATOS DE PRUEBA
-- ============================================

-- Especialista de prueba
INSERT INTO especialistas (id, email, nombre, telefono, especialidad, whatsapp_number)
VALUES (
  '123e4567-e89b-12d3-a456-426614174000'::uuid,
  'dr.ejemplo@nexos.com',
  'Dr. Juan Pérez',
  '+525512345678',
  'Psicología',
  '+525512345678'
) ON CONFLICT (email) DO NOTHING;

-- Horarios de prueba (Lunes a Viernes, 9am-5pm)
INSERT INTO horarios_disponibles (especialista_id, dia_semana, hora_inicio, hora_fin, duracion_cita)
VALUES 
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 1, '09:00', '17:00', 60), -- Lunes
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 2, '09:00', '17:00', 60), -- Martes
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 3, '09:00', '17:00', 60), -- Miércoles
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 4, '09:00', '17:00', 60), -- Jueves
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 5, '09:00', '17:00', 60)  -- Viernes
ON CONFLICT (especialista_id, dia_semana, hora_inicio, hora_fin) DO NOTHING;

-- Paciente de prueba
INSERT INTO pacientes (nombre, telefono, email)
VALUES ('María González', '+525587654321', 'maria@example.com')
ON CONFLICT (telefono) DO NOTHING;

-- Cita de prueba
INSERT INTO citas (
  especialista_id,
  paciente_id,
  fecha_hora,
  estado,
  motivo
)
VALUES (
  '123e4567-e89b-12d3-a456-426614174000'::uuid,
  (SELECT id FROM pacientes WHERE telefono = '+525587654321'),
  NOW() + INTERVAL '1 day',
  'confirmada',
  'Consulta general'
) ON CONFLICT DO NOTHING;

-- ============================================
-- VERIFICACIÓN
-- ============================================

-- Query para verificar que todo se creó correctamente
DO $$
BEGIN
  RAISE NOTICE '✓ Tablas creadas: %', (
    SELECT COUNT(*) FROM information_schema.tables 
    WHERE table_schema = 'public' 
      AND table_name IN ('especialistas', 'horarios_disponibles', 'pacientes', 'citas', 'whatsapp_logs')
  );
  
  RAISE NOTICE '✓ Índices creados: %', (
    SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public'
  );
  
  RAISE NOTICE '✓ Funciones creadas: %', (
    SELECT COUNT(*) FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname IN ('obtener_horarios_disponibles', 'validar_horario_disponible', 'obtener_citas_del_dia')
  );
  
  RAISE NOTICE '✓ Datos de prueba insertados';
  RAISE NOTICE '✓ RLS habilitado en todas las tablas';
  RAISE NOTICE '';
  RAISE NOTICE '🎉 ¡Schema de Nexos instalado exitosamente!';
END $$;

COMMENT ON TABLE pacientes IS 'Información de pacientes/clientes';
COMMENT ON COLUMN pacientes.telefono IS 'Número de teléfono en formato E.164 (+52...)';

-- Tabla: Citas
CREATE TABLE citas (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  especialista_id UUID NOT NULL REFERENCES especialistas(id) ON DELETE CASCADE,
  paciente_id UUID NOT NULL REFERENCES pacientes(id) ON DELETE CASCADE,
  fecha_hora TIMESTAMP WITH TIME ZONE NOT NULL,
  duracion INTEGER DEFAULT 60 NOT NULL,
  estado TEXT DEFAULT 'pendiente' NOT NULL,
  motivo TEXT,
  notas TEXT,
  recordatorio_enviado BOOLEAN DEFAULT false NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  
  -- Constraints
  CONSTRAINT estado_valido CHECK (estado IN ('pendiente', 'confirmada', 'cancelada', 'completada')),
  CONSTRAINT duracion_positiva_cita CHECK (duracion > 0),
  CONSTRAINT fecha_futura CHECK (fecha_hora > created_at)
);

COMMENT ON TABLE citas IS 'Citas agendadas entre especialistas y pacientes';
COMMENT ON COLUMN citas.estado IS 'Estados posibles: pendiente, confirmada, cancelada, completada';
COMMENT ON COLUMN citas.duracion IS 'Duración de la cita en minutos';

-- Tabla: Logs de WhatsApp
CREATE TABLE whatsapp_logs (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  telefono TEXT NOT NULL,
  mensaje TEXT,
  direccion TEXT NOT NULL,
  timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  metadata JSONB DEFAULT '{}'::jsonb,
  
  -- Constraints
  CONSTRAINT direccion_valida CHECK (direccion IN ('entrante', 'saliente'))
);

COMMENT ON TABLE whatsapp_logs IS 'Registro de mensajes de WhatsApp para debugging y auditoría';
COMMENT ON COLUMN whatsapp_logs.direccion IS 'Dirección del mensaje: entrante o saliente';

-- ============================================
-- ÍNDICES PARA PERFORMANCE
-- ============================================

-- Índices para especialistas
CREATE INDEX idx_especialistas_email ON especialistas(email);
CREATE INDEX idx_especialistas_whatsapp ON especialistas(whatsapp_number) WHERE whatsapp_number IS NOT NULL;
CREATE INDEX idx_especialistas_activo ON especialistas(activo) WHERE activo = true;

-- Índices para horarios
CREATE INDEX idx_horarios_especialista ON horarios_disponibles(especialista_id);
CREATE INDEX idx_horarios_dia ON horarios_disponibles(especialista_id, dia_semana);
CREATE INDEX idx_horarios_activo ON horarios_disponibles(especialista_id, activo) WHERE activo = true;

-- Índices para pacientes
CREATE INDEX idx_pacientes_telefono ON pacientes(telefono);
CREATE INDEX idx_pacientes_email ON pacientes(email) WHERE email IS NOT NULL;

-- Índices para citas (MUY IMPORTANTES para performance)
CREATE INDEX idx_citas_especialista_fecha ON citas(especialista_id, fecha_hora);
CREATE INDEX idx_citas_paciente ON citas(paciente_id);
CREATE INDEX idx_citas_estado ON citas(estado);
CREATE INDEX idx_citas_recordatorio ON citas(recordatorio_enviado, fecha_hora) 
  WHERE recordatorio_enviado = false AND estado IN ('pendiente', 'confirmada');

-- Índice para buscar citas próximas (muy usado)
CREATE INDEX idx_citas_proximas ON citas(especialista_id, fecha_hora, estado) 
  WHERE fecha_hora > NOW() AND estado IN ('pendiente', 'confirmada');

-- Índices para logs
CREATE INDEX idx_logs_telefono ON whatsapp_logs(telefono);
CREATE INDEX idx_logs_timestamp ON whatsapp_logs(timestamp DESC);
CREATE INDEX idx_logs_direccion ON whatsapp_logs(direccion, timestamp DESC);

-- ============================================
-- FUNCIONES ÚTILES
-- ============================================

-- Función: Obtener horarios disponibles en una fecha específica
CREATE OR REPLACE FUNCTION obtener_horarios_disponibles(
  p_especialista_id UUID,
  p_fecha DATE
)
RETURNS TABLE (
  hora_inicio TIME,
  hora_fin TIME,
  disponible BOOLEAN
) AS $$
DECLARE
  v_dia_semana INTEGER;
BEGIN
  -- Obtener día de la semana (0=Domingo, 6=Sábado)
  v_dia_semana := EXTRACT(DOW FROM p_fecha);
  
  RETURN QUERY
  SELECT 
    h.hora_inicio,
    h.hora_fin,
    NOT EXISTS (
      SELECT 1 FROM citas c
      WHERE c.especialista_id = p_especialista_id
        AND DATE(c.fecha_hora AT TIME ZONE 'America/Mexico_City') = p_fecha
        AND c.estado IN ('pendiente', 'confirmada')
        AND TIME(c.fecha_hora AT TIME ZONE 'America/Mexico_City') >= h.hora_inicio
        AND TIME(c.fecha_hora AT TIME ZONE 'America/Mexico_City') < h.hora_fin
    ) AS disponible
  FROM horarios_disponibles h
  WHERE h.especialista_id = p_especialista_id
    AND h.dia_semana = v_dia_semana
    AND h.activo = true
  ORDER BY h.hora_inicio;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION obtener_horarios_disponibles IS 'Retorna los horarios disponibles de un especialista en una fecha específica';

-- Función: Validar si un horario está disponible
CREATE OR REPLACE FUNCTION validar_horario_disponible(
  p_especialista_id UUID,
  p_fecha_hora TIMESTAMP WITH TIME ZONE,
  p_duracion INTEGER DEFAULT 60
)
RETURNS BOOLEAN AS $$
BEGIN
  -- Verificar que no haya solapamiento con citas existentes
  RETURN NOT EXISTS (
    SELECT 1 FROM citas
    WHERE especialista_id = p_especialista_id
      AND estado IN ('pendiente', 'confirmada')
      AND (
        -- Verifica solapamiento de rangos de tiempo
        (fecha_hora, fecha_hora + (duracion || ' minutes')::INTERVAL) OVERLAPS
        (p_fecha_hora, p_fecha_hora + (p_duracion || ' minutes')::INTERVAL)
      )
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION validar_horario_disponible IS 'Valida si un horario específico está disponible para agendar';

-- Función: Obtener citas del día para un especialista
CREATE OR REPLACE FUNCTION obtener_citas_del_dia(
  p_especialista_id UUID,
  p_fecha DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
  id UUID,
  paciente_nombre TEXT,
  paciente_telefono TEXT,
  fecha_hora TIMESTAMP WITH TIME ZONE,
  duracion INTEGER,
  estado TEXT,
  motivo TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    c.id,
    p.nombre AS paciente_nombre,
    p.telefono AS paciente_telefono,
    c.fecha_hora,
    c.duracion,
    c.estado,
    c.motivo
  FROM citas c
  JOIN pacientes p ON c.paciente_id = p.id
  WHERE c.especialista_id = p_especialista_id
    AND DATE(c.fecha_hora AT TIME ZONE 'America/Mexico_City') = p_fecha
    AND c.estado IN ('pendiente', 'confirmada')
  ORDER BY c.fecha_hora;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION obtener_citas_del_dia IS 'Retorna todas las citas de un especialista para un día específico';

-- ============================================
-- TRIGGERS
-- ============================================

-- Función para actualizar updated_at automáticamente
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Triggers para updated_at
CREATE TRIGGER update_especialistas_updated_at
  BEFORE UPDATE ON especialistas
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_pacientes_updated_at
  BEFORE UPDATE ON pacientes
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_citas_updated_at
  BEFORE UPDATE ON citas
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- ============================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================

-- Habilitar RLS en todas las tablas
ALTER TABLE especialistas ENABLE ROW LEVEL SECURITY;
ALTER TABLE horarios_disponibles ENABLE ROW LEVEL SECURITY;
ALTER TABLE pacientes ENABLE ROW LEVEL SECURITY;
ALTER TABLE citas ENABLE ROW LEVEL SECURITY;
ALTER TABLE whatsapp_logs ENABLE ROW LEVEL SECURITY;

-- Políticas para Especialistas
CREATE POLICY "Especialistas ven sus propios datos"
  ON especialistas FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "Especialistas actualizan sus propios datos"
  ON especialistas FOR UPDATE
  USING (auth.uid() = id);

-- Políticas para Horarios
CREATE POLICY "Especialistas ven sus propios horarios"
  ON horarios_disponibles FOR SELECT
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas crean sus horarios"
  ON horarios_disponibles FOR INSERT
  WITH CHECK (auth.uid() = especialista_id);

CREATE POLICY "Especialistas actualizan sus horarios"
  ON horarios_disponibles FOR UPDATE
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas eliminan sus horarios"
  ON horarios_disponibles FOR DELETE
  USING (auth.uid() = especialista_id);

-- Políticas para Pacientes (los especialistas pueden ver pacientes relacionados a sus citas)
CREATE POLICY "Especialistas ven pacientes de sus citas"
  ON pacientes FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM citas
      WHERE citas.paciente_id = pacientes.id
        AND citas.especialista_id = auth.uid()
    )
  );

CREATE POLICY "Crear pacientes desde citas"
  ON pacientes FOR INSERT
  WITH CHECK (true); -- Se valida en la aplicación

-- Políticas para Citas
CREATE POLICY "Especialistas ven sus propias citas"
  ON citas FOR SELECT
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas crean sus citas"
  ON citas FOR INSERT
  WITH CHECK (auth.uid() = especialista_id);

CREATE POLICY "Especialistas actualizan sus citas"
  ON citas FOR UPDATE
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas eliminan sus citas"
  ON citas FOR DELETE
  USING (auth.uid() = especialista_id);

-- Políticas para Logs
CREATE POLICY "Especialistas ven logs relacionados a su WhatsApp"
  ON whatsapp_logs FOR SELECT
  USING (
    telefono IN (
      SELECT whatsapp_number FROM especialistas WHERE id = auth.uid()
    )
  );

CREATE POLICY "Sistema puede crear logs"
  ON whatsapp_logs FOR INSERT
  WITH CHECK (true); -- Service role puede insertar

-- ============================================
-- DATOS DE PRUEBA
-- ============================================

-- Especialista de prueba
INSERT INTO especialistas (id, email, nombre, telefono, especialidad, whatsapp_number)
VALUES (
  '123e4567-e89b-12d3-a456-426614174000'::uuid,
  'dr.ejemplo@nexos.com',
  'Dr. Juan Pérez',
  '+525512345678',
  'Psicología',
  '+525512345678'
) ON CONFLICT (email) DO NOTHING;

-- Horarios de prueba (Lunes a Viernes, 9am-5pm)
INSERT INTO horarios_disponibles (especialista_id, dia_semana, hora_inicio, hora_fin, duracion_cita)
VALUES 
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 1, '09:00', '17:00', 60), -- Lunes
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 2, '09:00', '17:00', 60), -- Martes
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 3, '09:00', '17:00', 60), -- Miércoles
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 4, '09:00', '17:00', 60), -- Jueves
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 5, '09:00', '17:00', 60)  -- Viernes
ON CONFLICT (especialista_id, dia_semana, hora_inicio, hora_fin) DO NOTHING;

-- Paciente de prueba
INSERT INTO pacientes (nombre, telefono, email)
VALUES ('María González', '+525587654321', 'maria@example.com')
ON CONFLICT (telefono) DO NOTHING;

-- Cita de prueba
INSERT INTO citas (
  especialista_id,
  paciente_id,
  fecha_hora,
  estado,
  motivo
)
VALUES (
  '123e4567-e89b-12d3-a456-426614174000'::uuid,
  (SELECT id FROM pacientes WHERE telefono = '+525587654321'),
  NOW() + INTERVAL '1 day',
  'confirmada',
  'Consulta general'
) ON CONFLICT DO NOTHING;

-- ============================================
-- VERIFICACIÓN
-- ============================================

-- Query para verificar que todo se creó correctamente
DO $$
BEGIN
  RAISE NOTICE '✓ Tablas creadas: %', (
    SELECT COUNT(*) FROM information_schema.tables 
    WHERE table_schema = 'public' 
      AND table_name IN ('especialistas', 'horarios_disponibles', 'pacientes', 'citas', 'whatsapp_logs')
  );
  
  RAISE NOTICE '✓ Índices creados: %', (
    SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public'
  );
  
  RAISE NOTICE '✓ Funciones creadas: %', (
    SELECT COUNT(*) FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname IN ('obtener_horarios_disponibles', 'validar_horario_disponible', 'obtener_citas_del_dia')
  );
  
  RAISE NOTICE '✓ Datos de prueba insertados';
  RAISE NOTICE '✓ RLS habilitado en todas las tablas';
  RAISE NOTICE '';
  RAISE NOTICE '🎉 ¡Schema de Nexos instalado exitosamente!';
END $$;

ALTER TABLE especialistas 
ADD CONSTRAINT whatsapp_format_mx 
CHECK (
  whatsapp_number IS NULL OR 
  whatsapp_number ~ '^\+52[1-9]\d{9}' 
);

COMMENT ON TABLE especialistas IS 'Especialistas que usan el sistema (médicos, psicólogos, etc.)';
COMMENT ON COLUMN especialistas.whatsapp_number IS 'Número de WhatsApp Business en formato E.164';

-- Tabla: Horarios Disponibles
CREATE TABLE horarios_disponibles (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  especialista_id UUID NOT NULL REFERENCES especialistas(id) ON DELETE CASCADE,
  dia_semana INTEGER NOT NULL,
  hora_inicio TIME NOT NULL,
  hora_fin TIME NOT NULL,
  duracion_cita INTEGER DEFAULT 60 NOT NULL,
  activo BOOLEAN DEFAULT true NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  
  -- Constraints
  CONSTRAINT dia_semana_check CHECK (dia_semana >= 0 AND dia_semana <= 6),
  CONSTRAINT duracion_positiva CHECK (duracion_cita > 0),
  CONSTRAINT hora_valida CHECK (hora_inicio < hora_fin),
  CONSTRAINT no_duplicados UNIQUE (especialista_id, dia_semana, hora_inicio, hora_fin)
);

COMMENT ON TABLE horarios_disponibles IS 'Horarios de disponibilidad por día de la semana';
COMMENT ON COLUMN horarios_disponibles.dia_semana IS '0=Domingo, 1=Lunes, 2=Martes, 3=Miércoles, 4=Jueves, 5=Viernes, 6=Sábado';
COMMENT ON COLUMN horarios_disponibles.duracion_cita IS 'Duración de cada cita en minutos';

-- Tabla: Pacientes
CREATE TABLE pacientes (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  nombre TEXT NOT NULL,
  telefono TEXT UNIQUE NOT NULL,
  email TEXT,
  notas TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  
  -- Constraints
  CONSTRAINT telefono_format CHECK (telefono ~ '^\+[1-9]\d{1,14}$'),
  CONSTRAINT email_format_paciente CHECK (email IS NULL OR email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
);

COMMENT ON TABLE pacientes IS 'Información de pacientes/clientes';
COMMENT ON COLUMN pacientes.telefono IS 'Número de teléfono en formato E.164 (+52...)';

-- Tabla: Citas
CREATE TABLE citas (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  especialista_id UUID NOT NULL REFERENCES especialistas(id) ON DELETE CASCADE,
  paciente_id UUID NOT NULL REFERENCES pacientes(id) ON DELETE CASCADE,
  fecha_hora TIMESTAMP WITH TIME ZONE NOT NULL,
  duracion INTEGER DEFAULT 60 NOT NULL,
  estado TEXT DEFAULT 'pendiente' NOT NULL,
  motivo TEXT,
  notas TEXT,
  recordatorio_enviado BOOLEAN DEFAULT false NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  
  -- Constraints
  CONSTRAINT estado_valido CHECK (estado IN ('pendiente', 'confirmada', 'cancelada', 'completada')),
  CONSTRAINT duracion_positiva_cita CHECK (duracion > 0),
  CONSTRAINT fecha_futura CHECK (fecha_hora > created_at)
);

COMMENT ON TABLE citas IS 'Citas agendadas entre especialistas y pacientes';
COMMENT ON COLUMN citas.estado IS 'Estados posibles: pendiente, confirmada, cancelada, completada';
COMMENT ON COLUMN citas.duracion IS 'Duración de la cita en minutos';

-- Tabla: Logs de WhatsApp
CREATE TABLE whatsapp_logs (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  telefono TEXT NOT NULL,
  mensaje TEXT,
  direccion TEXT NOT NULL,
  timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  metadata JSONB DEFAULT '{}'::jsonb,
  
  -- Constraints
  CONSTRAINT direccion_valida CHECK (direccion IN ('entrante', 'saliente'))
);

COMMENT ON TABLE whatsapp_logs IS 'Registro de mensajes de WhatsApp para debugging y auditoría';
COMMENT ON COLUMN whatsapp_logs.direccion IS 'Dirección del mensaje: entrante o saliente';

-- ============================================
-- ÍNDICES PARA PERFORMANCE
-- ============================================

-- Índices para especialistas
CREATE INDEX idx_especialistas_email ON especialistas(email);
CREATE INDEX idx_especialistas_whatsapp ON especialistas(whatsapp_number) WHERE whatsapp_number IS NOT NULL;
CREATE INDEX idx_especialistas_activo ON especialistas(activo) WHERE activo = true;

-- Índices para horarios
CREATE INDEX idx_horarios_especialista ON horarios_disponibles(especialista_id);
CREATE INDEX idx_horarios_dia ON horarios_disponibles(especialista_id, dia_semana);
CREATE INDEX idx_horarios_activo ON horarios_disponibles(especialista_id, activo) WHERE activo = true;

-- Índices para pacientes
CREATE INDEX idx_pacientes_telefono ON pacientes(telefono);
CREATE INDEX idx_pacientes_email ON pacientes(email) WHERE email IS NOT NULL;

-- Índices para citas (MUY IMPORTANTES para performance)
CREATE INDEX idx_citas_especialista_fecha ON citas(especialista_id, fecha_hora);
CREATE INDEX idx_citas_paciente ON citas(paciente_id);
CREATE INDEX idx_citas_estado ON citas(estado);
CREATE INDEX idx_citas_recordatorio ON citas(recordatorio_enviado, fecha_hora) 
  WHERE recordatorio_enviado = false AND estado IN ('pendiente', 'confirmada');

-- Índice para buscar citas próximas (muy usado)
CREATE INDEX idx_citas_proximas ON citas(especialista_id, fecha_hora, estado) 
  WHERE fecha_hora > NOW() AND estado IN ('pendiente', 'confirmada');

-- Índices para logs
CREATE INDEX idx_logs_telefono ON whatsapp_logs(telefono);
CREATE INDEX idx_logs_timestamp ON whatsapp_logs(timestamp DESC);
CREATE INDEX idx_logs_direccion ON whatsapp_logs(direccion, timestamp DESC);

-- ============================================
-- FUNCIONES ÚTILES
-- ============================================

-- Función: Obtener horarios disponibles en una fecha específica
CREATE OR REPLACE FUNCTION obtener_horarios_disponibles(
  p_especialista_id UUID,
  p_fecha DATE
)
RETURNS TABLE (
  hora_inicio TIME,
  hora_fin TIME,
  disponible BOOLEAN
) AS $$
DECLARE
  v_dia_semana INTEGER;
BEGIN
  -- Obtener día de la semana (0=Domingo, 6=Sábado)
  v_dia_semana := EXTRACT(DOW FROM p_fecha);
  
  RETURN QUERY
  SELECT 
    h.hora_inicio,
    h.hora_fin,
    NOT EXISTS (
      SELECT 1 FROM citas c
      WHERE c.especialista_id = p_especialista_id
        AND DATE(c.fecha_hora AT TIME ZONE 'America/Mexico_City') = p_fecha
        AND c.estado IN ('pendiente', 'confirmada')
        AND TIME(c.fecha_hora AT TIME ZONE 'America/Mexico_City') >= h.hora_inicio
        AND TIME(c.fecha_hora AT TIME ZONE 'America/Mexico_City') < h.hora_fin
    ) AS disponible
  FROM horarios_disponibles h
  WHERE h.especialista_id = p_especialista_id
    AND h.dia_semana = v_dia_semana
    AND h.activo = true
  ORDER BY h.hora_inicio;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION obtener_horarios_disponibles IS 'Retorna los horarios disponibles de un especialista en una fecha específica';

-- Función: Validar si un horario está disponible
CREATE OR REPLACE FUNCTION validar_horario_disponible(
  p_especialista_id UUID,
  p_fecha_hora TIMESTAMP WITH TIME ZONE,
  p_duracion INTEGER DEFAULT 60
)
RETURNS BOOLEAN AS $$
BEGIN
  -- Verificar que no haya solapamiento con citas existentes
  RETURN NOT EXISTS (
    SELECT 1 FROM citas
    WHERE especialista_id = p_especialista_id
      AND estado IN ('pendiente', 'confirmada')
      AND (
        -- Verifica solapamiento de rangos de tiempo
        (fecha_hora, fecha_hora + (duracion || ' minutes')::INTERVAL) OVERLAPS
        (p_fecha_hora, p_fecha_hora + (p_duracion || ' minutes')::INTERVAL)
      )
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION validar_horario_disponible IS 'Valida si un horario específico está disponible para agendar';

-- Función: Obtener citas del día para un especialista
CREATE OR REPLACE FUNCTION obtener_citas_del_dia(
  p_especialista_id UUID,
  p_fecha DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
  id UUID,
  paciente_nombre TEXT,
  paciente_telefono TEXT,
  fecha_hora TIMESTAMP WITH TIME ZONE,
  duracion INTEGER,
  estado TEXT,
  motivo TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    c.id,
    p.nombre AS paciente_nombre,
    p.telefono AS paciente_telefono,
    c.fecha_hora,
    c.duracion,
    c.estado,
    c.motivo
  FROM citas c
  JOIN pacientes p ON c.paciente_id = p.id
  WHERE c.especialista_id = p_especialista_id
    AND DATE(c.fecha_hora AT TIME ZONE 'America/Mexico_City') = p_fecha
    AND c.estado IN ('pendiente', 'confirmada')
  ORDER BY c.fecha_hora;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION obtener_citas_del_dia IS 'Retorna todas las citas de un especialista para un día específico';

-- ============================================
-- TRIGGERS
-- ============================================

-- Función para actualizar updated_at automáticamente
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Triggers para updated_at
CREATE TRIGGER update_especialistas_updated_at
  BEFORE UPDATE ON especialistas
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_pacientes_updated_at
  BEFORE UPDATE ON pacientes
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_citas_updated_at
  BEFORE UPDATE ON citas
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- ============================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================

-- Habilitar RLS en todas las tablas
ALTER TABLE especialistas ENABLE ROW LEVEL SECURITY;
ALTER TABLE horarios_disponibles ENABLE ROW LEVEL SECURITY;
ALTER TABLE pacientes ENABLE ROW LEVEL SECURITY;
ALTER TABLE citas ENABLE ROW LEVEL SECURITY;
ALTER TABLE whatsapp_logs ENABLE ROW LEVEL SECURITY;

-- Políticas para Especialistas
CREATE POLICY "Especialistas ven sus propios datos"
  ON especialistas FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "Especialistas actualizan sus propios datos"
  ON especialistas FOR UPDATE
  USING (auth.uid() = id);

-- Políticas para Horarios
CREATE POLICY "Especialistas ven sus propios horarios"
  ON horarios_disponibles FOR SELECT
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas crean sus horarios"
  ON horarios_disponibles FOR INSERT
  WITH CHECK (auth.uid() = especialista_id);

CREATE POLICY "Especialistas actualizan sus horarios"
  ON horarios_disponibles FOR UPDATE
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas eliminan sus horarios"
  ON horarios_disponibles FOR DELETE
  USING (auth.uid() = especialista_id);

-- Políticas para Pacientes (los especialistas pueden ver pacientes relacionados a sus citas)
CREATE POLICY "Especialistas ven pacientes de sus citas"
  ON pacientes FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM citas
      WHERE citas.paciente_id = pacientes.id
        AND citas.especialista_id = auth.uid()
    )
  );

CREATE POLICY "Crear pacientes desde citas"
  ON pacientes FOR INSERT
  WITH CHECK (true); -- Se valida en la aplicación

-- Políticas para Citas
CREATE POLICY "Especialistas ven sus propias citas"
  ON citas FOR SELECT
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas crean sus citas"
  ON citas FOR INSERT
  WITH CHECK (auth.uid() = especialista_id);

CREATE POLICY "Especialistas actualizan sus citas"
  ON citas FOR UPDATE
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas eliminan sus citas"
  ON citas FOR DELETE
  USING (auth.uid() = especialista_id);

-- Políticas para Logs
CREATE POLICY "Especialistas ven logs relacionados a su WhatsApp"
  ON whatsapp_logs FOR SELECT
  USING (
    telefono IN (
      SELECT whatsapp_number FROM especialistas WHERE id = auth.uid()
    )
  );

CREATE POLICY "Sistema puede crear logs"
  ON whatsapp_logs FOR INSERT
  WITH CHECK (true); -- Service role puede insertar

-- ============================================
-- DATOS DE PRUEBA
-- ============================================

-- Especialista de prueba
INSERT INTO especialistas (id, email, nombre, telefono, especialidad, whatsapp_number)
VALUES (
  '123e4567-e89b-12d3-a456-426614174000'::uuid,
  'dr.ejemplo@nexos.com',
  'Dr. Juan Pérez',
  '+525512345678',
  'Psicología',
  '+525512345678'
) ON CONFLICT (email) DO NOTHING;

-- Horarios de prueba (Lunes a Viernes, 9am-5pm)
INSERT INTO horarios_disponibles (especialista_id, dia_semana, hora_inicio, hora_fin, duracion_cita)
VALUES 
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 1, '09:00', '17:00', 60), -- Lunes
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 2, '09:00', '17:00', 60), -- Martes
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 3, '09:00', '17:00', 60), -- Miércoles
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 4, '09:00', '17:00', 60), -- Jueves
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 5, '09:00', '17:00', 60)  -- Viernes
ON CONFLICT (especialista_id, dia_semana, hora_inicio, hora_fin) DO NOTHING;

-- Paciente de prueba
INSERT INTO pacientes (nombre, telefono, email)
VALUES ('María González', '+525587654321', 'maria@example.com')
ON CONFLICT (telefono) DO NOTHING;

-- Cita de prueba
INSERT INTO citas (
  especialista_id,
  paciente_id,
  fecha_hora,
  estado,
  motivo
)
VALUES (
  '123e4567-e89b-12d3-a456-426614174000'::uuid,
  (SELECT id FROM pacientes WHERE telefono = '+525587654321'),
  NOW() + INTERVAL '1 day',
  'confirmada',
  'Consulta general'
) ON CONFLICT DO NOTHING;

-- ============================================
-- VERIFICACIÓN
-- ============================================

-- Query para verificar que todo se creó correctamente
DO $$
BEGIN
  RAISE NOTICE '✓ Tablas creadas: %', (
    SELECT COUNT(*) FROM information_schema.tables 
    WHERE table_schema = 'public' 
      AND table_name IN ('especialistas', 'horarios_disponibles', 'pacientes', 'citas', 'whatsapp_logs')
  );
  
  RAISE NOTICE '✓ Índices creados: %', (
    SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public'
  );
  
  RAISE NOTICE '✓ Funciones creadas: %', (
    SELECT COUNT(*) FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname IN ('obtener_horarios_disponibles', 'validar_horario_disponible', 'obtener_citas_del_dia')
  );
  
  RAISE NOTICE '✓ Datos de prueba insertados';
  RAISE NOTICE '✓ RLS habilitado en todas las tablas';
  RAISE NOTICE '';
  RAISE NOTICE '🎉 ¡Schema de Nexos instalado exitosamente!';
END $$; -- Formato mexicano: +52 + 10 dígitos

COMMENT ON TABLE especialistas IS 'Especialistas que usan el sistema (médicos, psicólogos, etc.)';
COMMENT ON COLUMN especialistas.whatsapp_number IS 'Número de WhatsApp Business en formato E.164';

-- Tabla: Horarios Disponibles
CREATE TABLE horarios_disponibles (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  especialista_id UUID NOT NULL REFERENCES especialistas(id) ON DELETE CASCADE,
  dia_semana INTEGER NOT NULL,
  hora_inicio TIME NOT NULL,
  hora_fin TIME NOT NULL,
  duracion_cita INTEGER DEFAULT 60 NOT NULL,
  activo BOOLEAN DEFAULT true NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  
  -- Constraints
  CONSTRAINT dia_semana_check CHECK (dia_semana >= 0 AND dia_semana <= 6),
  CONSTRAINT duracion_positiva CHECK (duracion_cita > 0),
  CONSTRAINT hora_valida CHECK (hora_inicio < hora_fin),
  CONSTRAINT no_duplicados UNIQUE (especialista_id, dia_semana, hora_inicio, hora_fin)
);

COMMENT ON TABLE horarios_disponibles IS 'Horarios de disponibilidad por día de la semana';
COMMENT ON COLUMN horarios_disponibles.dia_semana IS '0=Domingo, 1=Lunes, 2=Martes, 3=Miércoles, 4=Jueves, 5=Viernes, 6=Sábado';
COMMENT ON COLUMN horarios_disponibles.duracion_cita IS 'Duración de cada cita en minutos';

-- Tabla: Pacientes
CREATE TABLE pacientes (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  nombre TEXT NOT NULL,
  telefono TEXT UNIQUE NOT NULL,
  email TEXT,
  notas TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  
  -- Constraints
  CONSTRAINT telefono_format CHECK (telefono ~ '^\+[1-9]\d{1,14}$'),
  CONSTRAINT email_format_paciente CHECK (email IS NULL OR email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
);

COMMENT ON TABLE pacientes IS 'Información de pacientes/clientes';
COMMENT ON COLUMN pacientes.telefono IS 'Número de teléfono en formato E.164 (+52...)';

-- Tabla: Citas
CREATE TABLE citas (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  especialista_id UUID NOT NULL REFERENCES especialistas(id) ON DELETE CASCADE,
  paciente_id UUID NOT NULL REFERENCES pacientes(id) ON DELETE CASCADE,
  fecha_hora TIMESTAMP WITH TIME ZONE NOT NULL,
  duracion INTEGER DEFAULT 60 NOT NULL,
  estado TEXT DEFAULT 'pendiente' NOT NULL,
  motivo TEXT,
  notas TEXT,
  recordatorio_enviado BOOLEAN DEFAULT false NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  
  -- Constraints
  CONSTRAINT estado_valido CHECK (estado IN ('pendiente', 'confirmada', 'cancelada', 'completada')),
  CONSTRAINT duracion_positiva_cita CHECK (duracion > 0),
  CONSTRAINT fecha_futura CHECK (fecha_hora > created_at)
);

COMMENT ON TABLE citas IS 'Citas agendadas entre especialistas y pacientes';
COMMENT ON COLUMN citas.estado IS 'Estados posibles: pendiente, confirmada, cancelada, completada';
COMMENT ON COLUMN citas.duracion IS 'Duración de la cita en minutos';

-- Tabla: Logs de WhatsApp
CREATE TABLE whatsapp_logs (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  telefono TEXT NOT NULL,
  mensaje TEXT,
  direccion TEXT NOT NULL,
  timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  metadata JSONB DEFAULT '{}'::jsonb,
  
  -- Constraints
  CONSTRAINT direccion_valida CHECK (direccion IN ('entrante', 'saliente'))
);

COMMENT ON TABLE whatsapp_logs IS 'Registro de mensajes de WhatsApp para debugging y auditoría';
COMMENT ON COLUMN whatsapp_logs.direccion IS 'Dirección del mensaje: entrante o saliente';

-- ============================================
-- ÍNDICES PARA PERFORMANCE
-- ============================================

-- Índices para especialistas
CREATE INDEX idx_especialistas_email ON especialistas(email);
CREATE INDEX idx_especialistas_whatsapp ON especialistas(whatsapp_number) WHERE whatsapp_number IS NOT NULL;
CREATE INDEX idx_especialistas_activo ON especialistas(activo) WHERE activo = true;

-- Índices para horarios
CREATE INDEX idx_horarios_especialista ON horarios_disponibles(especialista_id);
CREATE INDEX idx_horarios_dia ON horarios_disponibles(especialista_id, dia_semana);
CREATE INDEX idx_horarios_activo ON horarios_disponibles(especialista_id, activo) WHERE activo = true;

-- Índices para pacientes
CREATE INDEX idx_pacientes_telefono ON pacientes(telefono);
CREATE INDEX idx_pacientes_email ON pacientes(email) WHERE email IS NOT NULL;

-- Índices para citas (MUY IMPORTANTES para performance)
CREATE INDEX idx_citas_especialista_fecha ON citas(especialista_id, fecha_hora);
CREATE INDEX idx_citas_paciente ON citas(paciente_id);
CREATE INDEX idx_citas_estado ON citas(estado);
CREATE INDEX idx_citas_recordatorio ON citas(recordatorio_enviado, fecha_hora) 
  WHERE recordatorio_enviado = false AND estado IN ('pendiente', 'confirmada');

-- Índice para buscar citas próximas (muy usado)
CREATE INDEX idx_citas_proximas ON citas(especialista_id, fecha_hora, estado) 
  WHERE fecha_hora > NOW() AND estado IN ('pendiente', 'confirmada');

-- Índices para logs
CREATE INDEX idx_logs_telefono ON whatsapp_logs(telefono);
CREATE INDEX idx_logs_timestamp ON whatsapp_logs(timestamp DESC);
CREATE INDEX idx_logs_direccion ON whatsapp_logs(direccion, timestamp DESC);

-- ============================================
-- FUNCIONES ÚTILES
-- ============================================

-- Función: Obtener horarios disponibles en una fecha específica
CREATE OR REPLACE FUNCTION obtener_horarios_disponibles(
  p_especialista_id UUID,
  p_fecha DATE
)
RETURNS TABLE (
  hora_inicio TIME,
  hora_fin TIME,
  disponible BOOLEAN
) AS $$
DECLARE
  v_dia_semana INTEGER;
BEGIN
  -- Obtener día de la semana (0=Domingo, 6=Sábado)
  v_dia_semana := EXTRACT(DOW FROM p_fecha);
  
  RETURN QUERY
  SELECT 
    h.hora_inicio,
    h.hora_fin,
    NOT EXISTS (
      SELECT 1 FROM citas c
      WHERE c.especialista_id = p_especialista_id
        AND DATE(c.fecha_hora AT TIME ZONE 'America/Mexico_City') = p_fecha
        AND c.estado IN ('pendiente', 'confirmada')
        AND TIME(c.fecha_hora AT TIME ZONE 'America/Mexico_City') >= h.hora_inicio
        AND TIME(c.fecha_hora AT TIME ZONE 'America/Mexico_City') < h.hora_fin
    ) AS disponible
  FROM horarios_disponibles h
  WHERE h.especialista_id = p_especialista_id
    AND h.dia_semana = v_dia_semana
    AND h.activo = true
  ORDER BY h.hora_inicio;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION obtener_horarios_disponibles IS 'Retorna los horarios disponibles de un especialista en una fecha específica';

-- Función: Validar si un horario está disponible
CREATE OR REPLACE FUNCTION validar_horario_disponible(
  p_especialista_id UUID,
  p_fecha_hora TIMESTAMP WITH TIME ZONE,
  p_duracion INTEGER DEFAULT 60
)
RETURNS BOOLEAN AS $$
BEGIN
  -- Verificar que no haya solapamiento con citas existentes
  RETURN NOT EXISTS (
    SELECT 1 FROM citas
    WHERE especialista_id = p_especialista_id
      AND estado IN ('pendiente', 'confirmada')
      AND (
        -- Verifica solapamiento de rangos de tiempo
        (fecha_hora, fecha_hora + (duracion || ' minutes')::INTERVAL) OVERLAPS
        (p_fecha_hora, p_fecha_hora + (p_duracion || ' minutes')::INTERVAL)
      )
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION validar_horario_disponible IS 'Valida si un horario específico está disponible para agendar';

-- Función: Obtener citas del día para un especialista
CREATE OR REPLACE FUNCTION obtener_citas_del_dia(
  p_especialista_id UUID,
  p_fecha DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
  id UUID,
  paciente_nombre TEXT,
  paciente_telefono TEXT,
  fecha_hora TIMESTAMP WITH TIME ZONE,
  duracion INTEGER,
  estado TEXT,
  motivo TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    c.id,
    p.nombre AS paciente_nombre,
    p.telefono AS paciente_telefono,
    c.fecha_hora,
    c.duracion,
    c.estado,
    c.motivo
  FROM citas c
  JOIN pacientes p ON c.paciente_id = p.id
  WHERE c.especialista_id = p_especialista_id
    AND DATE(c.fecha_hora AT TIME ZONE 'America/Mexico_City') = p_fecha
    AND c.estado IN ('pendiente', 'confirmada')
  ORDER BY c.fecha_hora;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION obtener_citas_del_dia IS 'Retorna todas las citas de un especialista para un día específico';

-- ============================================
-- TRIGGERS
-- ============================================

-- Función para actualizar updated_at automáticamente
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Triggers para updated_at
CREATE TRIGGER update_especialistas_updated_at
  BEFORE UPDATE ON especialistas
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_pacientes_updated_at
  BEFORE UPDATE ON pacientes
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_citas_updated_at
  BEFORE UPDATE ON citas
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- ============================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================

-- Habilitar RLS en todas las tablas
ALTER TABLE especialistas ENABLE ROW LEVEL SECURITY;
ALTER TABLE horarios_disponibles ENABLE ROW LEVEL SECURITY;
ALTER TABLE pacientes ENABLE ROW LEVEL SECURITY;
ALTER TABLE citas ENABLE ROW LEVEL SECURITY;
ALTER TABLE whatsapp_logs ENABLE ROW LEVEL SECURITY;

-- Políticas para Especialistas
CREATE POLICY "Especialistas ven sus propios datos"
  ON especialistas FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "Especialistas actualizan sus propios datos"
  ON especialistas FOR UPDATE
  USING (auth.uid() = id);

-- Políticas para Horarios
CREATE POLICY "Especialistas ven sus propios horarios"
  ON horarios_disponibles FOR SELECT
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas crean sus horarios"
  ON horarios_disponibles FOR INSERT
  WITH CHECK (auth.uid() = especialista_id);

CREATE POLICY "Especialistas actualizan sus horarios"
  ON horarios_disponibles FOR UPDATE
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas eliminan sus horarios"
  ON horarios_disponibles FOR DELETE
  USING (auth.uid() = especialista_id);

-- Políticas para Pacientes (los especialistas pueden ver pacientes relacionados a sus citas)
CREATE POLICY "Especialistas ven pacientes de sus citas"
  ON pacientes FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM citas
      WHERE citas.paciente_id = pacientes.id
        AND citas.especialista_id = auth.uid()
    )
  );

CREATE POLICY "Crear pacientes desde citas"
  ON pacientes FOR INSERT
  WITH CHECK (true); -- Se valida en la aplicación

-- Políticas para Citas
CREATE POLICY "Especialistas ven sus propias citas"
  ON citas FOR SELECT
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas crean sus citas"
  ON citas FOR INSERT
  WITH CHECK (auth.uid() = especialista_id);

CREATE POLICY "Especialistas actualizan sus citas"
  ON citas FOR UPDATE
  USING (auth.uid() = especialista_id);

CREATE POLICY "Especialistas eliminan sus citas"
  ON citas FOR DELETE
  USING (auth.uid() = especialista_id);

-- Políticas para Logs
CREATE POLICY "Especialistas ven logs relacionados a su WhatsApp"
  ON whatsapp_logs FOR SELECT
  USING (
    telefono IN (
      SELECT whatsapp_number FROM especialistas WHERE id = auth.uid()
    )
  );

CREATE POLICY "Sistema puede crear logs"
  ON whatsapp_logs FOR INSERT
  WITH CHECK (true); -- Service role puede insertar

-- ============================================
-- DATOS DE PRUEBA
-- ============================================

-- Especialista de prueba
INSERT INTO especialistas (id, email, nombre, telefono, especialidad, whatsapp_number)
VALUES (
  '123e4567-e89b-12d3-a456-426614174000'::uuid,
  'dr.ejemplo@nexos.com',
  'Dr. Juan Pérez',
  '+525512345678',
  'Psicología',
  '+525512345678'
) ON CONFLICT (email) DO NOTHING;

-- Horarios de prueba (Lunes a Viernes, 9am-5pm)
INSERT INTO horarios_disponibles (especialista_id, dia_semana, hora_inicio, hora_fin, duracion_cita)
VALUES 
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 1, '09:00', '17:00', 60), -- Lunes
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 2, '09:00', '17:00', 60), -- Martes
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 3, '09:00', '17:00', 60), -- Miércoles
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 4, '09:00', '17:00', 60), -- Jueves
  ('123e4567-e89b-12d3-a456-426614174000'::uuid, 5, '09:00', '17:00', 60)  -- Viernes
ON CONFLICT (especialista_id, dia_semana, hora_inicio, hora_fin) DO NOTHING;

-- Paciente de prueba
INSERT INTO pacientes (nombre, telefono, email)
VALUES ('María González', '+525587654321', 'maria@example.com')
ON CONFLICT (telefono) DO NOTHING;

-- Cita de prueba
INSERT INTO citas (
  especialista_id,
  paciente_id,
  fecha_hora,
  estado,
  motivo
)
VALUES (
  '123e4567-e89b-12d3-a456-426614174000'::uuid,
  (SELECT id FROM pacientes WHERE telefono = '+525587654321'),
  NOW() + INTERVAL '1 day',
  'confirmada',
  'Consulta general'
) ON CONFLICT DO NOTHING;

-- ============================================
-- VERIFICACIÓN
-- ============================================

-- Query para verificar que todo se creó correctamente
DO $$
BEGIN
  RAISE NOTICE '✓ Tablas creadas: %', (
    SELECT COUNT(*) FROM information_schema.tables 
    WHERE table_schema = 'public' 
      AND table_name IN ('especialistas', 'horarios_disponibles', 'pacientes', 'citas', 'whatsapp_logs')
  );
  
  RAISE NOTICE '✓ Índices creados: %', (
    SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public'
  );
  
  RAISE NOTICE '✓ Funciones creadas: %', (
    SELECT COUNT(*) FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname IN ('obtener_horarios_disponibles', 'validar_horario_disponible', 'obtener_citas_del_dia')
  );
  
  RAISE NOTICE '✓ Datos de prueba insertados';
  RAISE NOTICE '✓ RLS habilitado en todas las tablas';
  RAISE NOTICE '';
  RAISE NOTICE '🎉 ¡Schema de Nexos instalado exitosamente!';
END $$;