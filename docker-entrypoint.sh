#!/bin/sh

psql -v $POSTGRES_DB -f /docker-entrypoint-initdb.d/audit.sql