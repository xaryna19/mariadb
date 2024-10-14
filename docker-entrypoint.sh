#!/bin/sh

# Exit on non defined variables and on non zero exit codes
set -eu

# Function to read secret from file
read_secret() {
    local secret_file="$1"
    if [ -f "$secret_file" ] && [ -r "$secret_file" ]; then
        cat "$secret_file"
    else
        echo ""
    fi
}

# Set MYSQL_ variables based on MARIADB_ variables or secrets if MYSQL_ is not set
for var in ROOT_PASSWORD DATABASE USER PASSWORD CHARSET COLLATION; do
    eval mysql_var="\$MYSQL_${var}"
    eval mariadb_var="\$MARIADB_${var}"
    
    # Check environment variables
    if [ -z "$mysql_var" ] && [ -n "$mariadb_var" ]; then
        eval "export MYSQL_${var}=\$mariadb_var"
    fi
    
    # Check secrets
    mysql_secret="/run/secrets/mysql_$(echo $var | tr '[:upper:]' '[:lower:]')"
    mariadb_secret="/run/secrets/mariadb_$(echo $var | tr '[:upper:]' '[:lower:]')"
    
    if [ -z "$mysql_var" ] && [ -f "$mariadb_secret" ]; then
        eval "export MYSQL_${var}=$(read_secret "$mariadb_secret")"
    elif [ -z "$mysql_var" ] && [ -f "$mysql_secret" ]; then
        eval "export MYSQL_${var}=$(read_secret "$mysql_secret")"
    fi
done

# Handle *_FILE variables
for var in ROOT_PASSWORD DATABASE USER PASSWORD; do
    eval mysql_var="\$MYSQL_${var}"
    eval mysql_file_var="\$MYSQL_${var}_FILE"
    eval mariadb_file_var="\$MARIADB_${var}_FILE"
    
    if [ -z "$mysql_var" ] && [ -n "$mysql_file_var" ]; then
        eval "export MYSQL_${var}=$(read_secret "$mysql_file_var")"
    elif [ -z "$mysql_var" ] && [ -n "$mariadb_file_var" ]; then
        eval "export MYSQL_${var}=$(read_secret "$mariadb_file_var")"
    fi
done

# execute any pre-init scripts
for i in /scripts/pre-init.d/*sh
do
    if [ -e "${i}" ]; then
        echo "[i] pre-init.d - processing $i"
        . "${i}"
    fi
done

if [ -d "/run/mysqld" ]; then
    echo "[i] mysqld already present, skipping creation"
    chown -R mysql:mysql /run/mysqld
else
    echo "[i] mysqld not found, creating...."
    mkdir -p /run/mysqld
    chown -R mysql:mysql /run/mysqld
fi

if [ -d /var/lib/mysql/mysql ]; then
    echo "[i] MySQL directory already present, skipping creation"
    chown -R mysql:mysql /var/lib/mysql
else
    echo "[i] MySQL data directory not found, creating initial DBs"

    chown -R mysql:mysql /var/lib/mysql

    mysql_install_db --user=mysql --ldata=/var/lib/mysql > /dev/null

    MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-""}
    MYSQL_DATABASE=${MYSQL_DATABASE:-""}
    MYSQL_USER=${MYSQL_USER:-""}
    MYSQL_PASSWORD=${MYSQL_PASSWORD:-""}

    tfile=$(mktemp)
    if [ ! -f "$tfile" ]; then
        return 1
    fi

    cat << EOF > $tfile
USE mysql;
FLUSH PRIVILEGES ;
GRANT ALL ON *.* TO 'root'@'%' identified by '$MYSQL_ROOT_PASSWORD' WITH GRANT OPTION ;
GRANT ALL ON *.* TO 'root'@'localhost' identified by '$MYSQL_ROOT_PASSWORD' WITH GRANT OPTION ;
SET PASSWORD FOR 'root'@'localhost'=PASSWORD('${MYSQL_ROOT_PASSWORD}') ;
DROP DATABASE IF EXISTS test ;
FLUSH PRIVILEGES ;
EOF

    if [ "$MYSQL_DATABASE" != "" ]; then
        echo "[i] Creating database: $MYSQL_DATABASE"
        if [ "$MYSQL_CHARSET" != "" ] && [ "$MYSQL_COLLATION" != "" ]; then
            echo "[i] with character set [$MYSQL_CHARSET] and collation [$MYSQL_COLLATION]"
            echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` CHARACTER SET $MYSQL_CHARSET COLLATE $MYSQL_COLLATION;" >> $tfile
        else
            echo "[i] with character set: 'utf8' and collation: 'utf8_general_ci'"
            echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` CHARACTER SET utf8 COLLATE utf8_general_ci;" >> $tfile
        fi

        if [ "$MYSQL_USER" != "" ]; then
            echo "[i] Creating user: $MYSQL_USER with password $MYSQL_PASSWORD"
            echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* to '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD';" >> $tfile
        fi
    fi

    /usr/bin/mysqld --user=mysql --bootstrap --verbose=0 --skip-name-resolve --skip-networking=0 < $tfile
    rm -f $tfile

    # only run if we have a starting MYSQL_DATABASE env variable AND
    # the /docker-entrypoint-initdb.d/ file is not empty
    if [ "$MYSQL_DATABASE" != "" ] && [ "$(ls -A /docker-entrypoint-initdb.d 2>/dev/null)" ]; then

        # start the server temporarily so that we can import seed files
        echo
        echo "Preparing to process the contents of /docker-entrypoint-initdb.d/"
        echo
        TEMP_OUTPUT_LOG=/tmp/mysqld_output
        /usr/bin/mysqld --user=mysql --skip-name-resolve --skip-networking=0 --silent-startup > "${TEMP_OUTPUT_LOG}" 2>&1 &
        PID="$!"
        
        # watch the output log until the server is running
        until tail "${TEMP_OUTPUT_LOG}" | grep -q "Version:"; do
            sleep 0.2
        done

        # use mysql client to import seed files while temp db is running
        # use the starting MYSQL_DATABASE so mysql knows where to import
        MYSQL_CLIENT="/usr/bin/mysql -u root -p$MYSQL_ROOT_PASSWORD"
        
        # loop through all the files in the seed directory
        # redirect input (<) from .sql files into the mysql client command line
        # pipe (|) the output of using `gunzip -c` on .sql.gz files
        for f in /docker-entrypoint-initdb.d/*; do
            case "$f" in
                *.sql)    echo "  $0: running $f"; eval "${MYSQL_CLIENT} ${MYSQL_DATABASE} < $f"; echo ;;
                *.sql.gz) echo "  $0: running $f"; gunzip -c "$f" | eval "${MYSQL_CLIENT} ${MYSQL_DATABASE}"; echo ;;
            esac
        done

        # send the temporary mysqld server a shutdown signal
        # and wait till it's done before completeing the init process
        kill -s TERM "${PID}"
        wait "${PID}"
        rm -f TEMP_OUTPUT_LOG
        echo "Completed processing seed files."
    fi;

    echo
    echo 'MySQL init process done. Ready for start up.'
    echo

    echo "exec /usr/bin/mysqld --user=mysql --console --skip-name-resolve --skip-networking=0" "$@"
fi

# execute any pre-exec scripts
for i in /scripts/pre-exec.d/*sh
do
    if [ -e "${i}" ]; then
        echo "[i] pre-exec.d - processing $i"
        . ${i}
    fi
done

exec /usr/bin/mysqld --user=mysql --console --skip-name-resolve --skip-networking=0 $@
