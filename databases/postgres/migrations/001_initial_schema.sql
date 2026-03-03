CREATE TABLE users         (id UUID PRIMARY KEY, email TEXT UNIQUE NOT NULL, role TEXT NOT NULL, created_at TIMESTAMPTZ DEFAULT NOW());
CREATE TABLE vehicles      (id UUID PRIMARY KEY, make TEXT, model TEXT, year INT, owner_id UUID REFERENCES users(id));
CREATE TABLE ecus          (id UUID PRIMARY KEY, vehicle_id UUID REFERENCES vehicles(id), brand TEXT, name TEXT);
CREATE TABLE tunes         (id UUID PRIMARY KEY, vehicle_id UUID REFERENCES vehicles(id), name TEXT, created_by UUID REFERENCES users(id));
CREATE TABLE tune_versions (id UUID PRIMARY KEY, tune_id UUID REFERENCES tunes(id), version INT, rom_s3_key TEXT, created_at TIMESTAMPTZ DEFAULT NOW());
CREATE TABLE datalogs_meta (id UUID PRIMARY KEY, vehicle_id UUID REFERENCES vehicles(id), session_start TIMESTAMPTZ, s3_key TEXT);
CREATE TABLE audit_logs    (id UUID PRIMARY KEY, user_id UUID REFERENCES users(id), action TEXT, details JSONB, created_at TIMESTAMPTZ DEFAULT NOW());
