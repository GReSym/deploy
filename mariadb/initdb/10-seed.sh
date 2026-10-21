# Sourced by docker-entrypoint.sh on the first start (empty data dir), so its helper functions are available.
# Imports the newest dump from ./mariadb/seed (mounted at /seed) into $MARIADB_DATABASE.
# Dumps made by `backend/manage.sh database dump` have no CREATE DATABASE/USE, so any database name works.
seed_file="$(ls -1t /seed/*.sql /seed/*.sql.gz /seed/*.sql.xz /seed/*.sql.zst 2>/dev/null | head -n 1)"
if [ -n "${seed_file}" ]; then
    mysql_note "Importing seed dump ${seed_file} (takes a few minutes)"
    docker_process_init_files "${seed_file}"
else
    mysql_note "No seed dump in /seed, starting with an empty database"
fi
