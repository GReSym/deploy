# Sourced by docker-entrypoint.sh on the first start (empty data dir), so its helper functions are available.
# Keep this file non-executable: executable scripts run in a subshell without those helpers.
# Creates the read-only user (ML service, ~/.my.cnf). '%' because host connections through the published
# port come from the docker bridge, not localhost.
if [ -n "${GRESYM_READONLY_USER:-}" ]; then
    mysql_note "Creating read-only user ${GRESYM_READONLY_USER}"
    readonly_user="$(docker_sql_escape_string_literal "${GRESYM_READONLY_USER}")"
    readonly_password="$(docker_sql_escape_string_literal "${GRESYM_READONLY_PASSWORD:-}")"
    docker_process_sql --database=mysql <<-EOSQL
		CREATE USER IF NOT EXISTS '${readonly_user}'@'%' IDENTIFIED BY '${readonly_password}';
		GRANT SELECT, SHOW VIEW ON \`${MARIADB_DATABASE}\`.* TO '${readonly_user}'@'%';
	EOSQL
fi
