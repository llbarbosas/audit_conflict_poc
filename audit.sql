CREATE TABLE audit (
    table_name text not null,
    record_pks text[],
    timestamp timestamp with time zone not null default current_timestamp,
    action char(1) NOT NULL check (action in ('I','D','U')),
    old_data jsonb,
    new_data jsonb,
    query text
);

CREATE OR REPLACE FUNCTION jsonb_diff_val(val1 JSONB,val2 JSONB)
RETURNS JSONB AS $$
DECLARE
  result JSONB;
  v RECORD;
BEGIN
   result = val1;
   FOR v IN SELECT * FROM jsonb_each(val2) LOOP
     IF result @> jsonb_build_object(v.key,v.value)
        THEN result = result - v.key;
     ELSIF result ? v.key THEN CONTINUE;
     ELSE
        result = result || jsonb_build_object(v.key,'null');
     END IF;
   END LOOP;
   RETURN result;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_table_pks(table_name TEXT) RETURNS TEXT[] AS $$
    SELECT array_agg(attname::TEXT) as pks
        FROM pg_index
        JOIN pg_attribute ON attrelid = indrelid AND attnum = ANY(indkey) 
        WHERE indrelid = table_name::regclass AND indisprimary
        GROUP BY indrelid;
$$ LANGUAGE SQL;

CREATE OR REPLACE FUNCTION get_record_pks(table_record jsonb, table_name TEXT) RETURNS TEXT[] AS $$
    SELECT array_agg(table_record->pk::TEXT) FROM unnest(get_table_pks(table_name)) AS pk
$$ LANGUAGE SQL;

CREATE OR REPLACE FUNCTION audit_trigger() RETURNS trigger AS $$
BEGIN
    if (TG_OP = 'UPDATE') then
        insert into audit (table_name,record_pks,action,old_data,new_data,query) 
            values (TG_TABLE_NAME::TEXT,get_record_pks(row_to_json(NEW)::jsonb, TG_TABLE_NAME::TEXT),substring(TG_OP,1,1),jsonb_diff_val(row_to_json(OLD)::JSONB, row_to_json(NEW)::JSONB),jsonb_diff_val(row_to_json(NEW)::JSONB, row_to_json(OLD)::JSONB),current_query());
        RETURN NEW;
    elsif (TG_OP = 'DELETE') then
        insert into audit (table_name,record_pks,action,old_data,query) 
            values (TG_TABLE_NAME::TEXT,get_record_pks(row_to_json(NEW)::jsonb, TG_TABLE_NAME::TEXT),substring(TG_OP,1,1),row_to_json(OLD)::JSONB,current_query());
        RETURN OLD;
    elsif (TG_OP = 'INSERT') then
        insert into audit (table_name,record_pks,action,new_data,query) 
            values (TG_TABLE_NAME::TEXT,get_record_pks(row_to_json(NEW)::jsonb, TG_TABLE_NAME::TEXT),substring(TG_OP,1,1),row_to_json(NEW)::JSONB,current_query());
        RETURN NEW;
    else
        RAISE WARNING '[AUDIT.IF_MODIFIED_FUNC] - Other action occurred: %, at %',TG_OP,now();
        RETURN NULL;
    end if;
END;
$$
LANGUAGE plpgsql;

CREATE VIEW audit_conflict AS SELECT 
    EXTRACT(EPOCH FROM (audit.timestamp - audit2.timestamp)) as timestamp_diff, audit.table_name, audit.record_pks, 
	audit.action as audit1_action, audit2.action as audit2_action, audit.old_data as audit1_old_data, 
	audit2.old_data as audit2_old_data, audit.new_data as audit1_new_data, audit2.new_data as audit2_new_data
	FROM audit 
		JOIN audit as audit2 ON audit2.record_pks = audit.record_pks
	WHERE EXTRACT(EPOCH FROM (audit.timestamp - audit2.timestamp)) BETWEEN 1 AND 30;


----------------------------
------ Teste ---------------
----------------------------

CREATE TABLE test_table (pk_1 integer, pk_2 integer, value text, primary key (pk_1, pk_2));

CREATE TRIGGER test_table_audit BEFORE INSERT OR UPDATE OR DELETE ON test_table
    FOR EACH ROW EXECUTE PROCEDURE audit_trigger();

INSERT INTO test_table VALUES (0, 1, 'teste 1'),  (2, 3, 'teste 2'),  (4, 5, 'teste 1');

-- Gerar conflito:
UPDATE test_table SET value = 'teste 1 alterado por fulano' WHERE pk_1 = 0;
UPDATE test_table SET value = 'teste 1 alterado por ciclano' WHERE pk_1 = 0;

-- Ver conflito gerado:
-- SELECT * FROM audit_conflict