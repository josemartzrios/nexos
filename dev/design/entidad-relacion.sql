-- ============================================
-- NEXOS - Sistema de Agendamiento WhatsApp
-- Diagrama Entidad-Relación para dbdiagram.io
-- ============================================

-- Tabla: Especialistas
Table especialistas {
  id uuid [pk, default: `gen_random_uuid()`]
  email text [unique, not null]
  nombre text [not null]
  telefono text
  especialidad text
  whatsapp_number text [unique, note: 'Número de WhatsApp Business']
  created_at timestamp [default: `now()`]
  updated_at timestamp [default: `now()`]
  activo boolean [default: true]
  
  Note: 'Especialistas que usan el sistema (médicos, psicólogos, etc.)'
}

-- Tabla: Horarios Disponibles
Table horarios_disponibles {
  id uuid [pk, default: `gen_random_uuid()`]
  especialista_id uuid [ref: > especialistas.id, not null]
  dia_semana integer [not null, note: '0=Domingo, 1=Lunes, ..., 6=Sábado']
  hora_inicio time [not null]
  hora_fin time [not null]
  duracion_cita integer [default: 60, note: 'Duración en minutos']
  activo boolean [default: true]
  created_at timestamp [default: `now()`]
  
  indexes {
    especialista_id
    (especialista_id, dia_semana)
  }
  
  Note: 'Horarios de disponibilidad por día de la semana'
}

-- Tabla: Pacientes
Table pacientes {
  id uuid [pk, default: `gen_random_uuid()`]
  nombre text [not null]
  telefono text [unique, not null]
  email text
  notas text
  created_at timestamp [default: `now()`]
  updated_at timestamp [default: `now()`]
  
  indexes {
    telefono
  }
  
  Note: 'Información de pacientes/clientes'
}

-- Tabla: Citas
Table citas {
  id uuid [pk, default: `gen_random_uuid()`]
  especialista_id uuid [ref: > especialistas.id, not null]
  paciente_id uuid [ref: > pacientes.id, not null]
  fecha_hora timestamp [not null]
  duracion integer [default: 60, note: 'Duración en minutos']
  estado text [default: 'pendiente', note: 'pendiente, confirmada, cancelada, completada']
  motivo text
  notas text
  recordatorio_enviado boolean [default: false]
  created_at timestamp [default: `now()`]
  updated_at timestamp [default: `now()`]
  
  indexes {
    (especialista_id, fecha_hora)
    estado
    paciente_id
  }
  
  Note: 'Citas agendadas entre especialistas y pacientes'
}

-- Tabla: Logs de WhatsApp
Table whatsapp_logs {
  id uuid [pk, default: `gen_random_uuid()`]
  telefono text [not null]
  mensaje text
  direccion text [note: 'entrante o saliente']
  timestamp timestamp [default: `now()`]
  metadata jsonb
  
  indexes {
    telefono
    timestamp
  }
  
  Note: 'Registro de mensajes de WhatsApp para debugging y auditoría'
}

-- ============================================
-- RELACIONES
-- ============================================

-- Un especialista tiene muchos horarios disponibles
-- Ref: horarios_disponibles.especialista_id > especialistas.id [delete: cascade]

-- Un especialista tiene muchas citas
-- Ref: citas.especialista_id > especialistas.id [delete: cascade]

-- Un paciente tiene muchas citas
-- Ref: citas.paciente_id > pacientes.id [delete: cascade]

-- ============================================
-- NOTAS GENERALES
-- ============================================

Note proyecto {
  '''
  # Sistema Nexos - Agendamiento Automático WhatsApp
  
  ## Flujo Principal:
  1. Paciente envía mensaje a WhatsApp
  2. Bot consulta horarios_disponibles del especialista
  3. Paciente selecciona horario y confirma
  4. Se crea registro en tabla citas
  5. Se envía confirmación automática
  6. Sistema envía recordatorio 24h antes
  
  ## Relaciones Clave:
  - Especialista 1:N Horarios (un especialista tiene múltiples horarios)
  - Especialista 1:N Citas (un especialista tiene múltiples citas)
  - Paciente 1:N Citas (un paciente puede tener múltiples citas)
  
  ## Índices Importantes:
  - citas(especialista_id, fecha_hora) para búsquedas rápidas
  - pacientes(telefono) para lookup de pacientes por WhatsApp
  - horarios_disponibles(especialista_id) para consulta de disponibilidad
  
  ## Seguridad:
  - Row Level Security (RLS) habilitado en todas las tablas
  - Especialistas solo ven sus propios datos
  - Autenticación vía Supabase Auth
  '''
}