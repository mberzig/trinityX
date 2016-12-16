#!/bin/bash

######################################################################
# TrinityX
# Copyright (c) 2016  ClusterVision B.V.
# 
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License (included with the sources) for more
# details.
######################################################################

display_var HA PRIMARY_INSTALL TRIX_CTRL{1,2}_HOSTNAME

# -------------------------------------

# Utility functions

function do_sql_req {
    echo $@ | /usr/bin/mysql
}

function pass_esc {
    echo "$1" | sed 's/\(['"'"'\]\)/\\\1/g'
}

function setup_root_pass {
    PASS=`pass_esc $1`

    do_sql_req "UPDATE mysql.user SET Password=PASSWORD('$PASS') WHERE User='root';"
    do_sql_req "FLUSH PRIVILEGES;"

    # Save default mysql root credentials to avoid having to provide then in every cmd
    # This here is heredocument that uses the "-EOF" operator to improve readability
    # Leading TABS (not spaces) are ignored.
    cat <<-EOF > ~/.my.cnf
		[mysql]
		user=root
		password=$PASS
		[mysqldump]
		user=root
		password=$PASS
		EOF
    chmod 600 ~/.my.cnf
}

function remove_test_db {
    do_sql_req "DROP DATABASE IF EXISTS test;"
    do_sql_req "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%'"
}

function remove_anonymous_users {
    do_sql_req "DELETE FROM mysql.user WHERE User='';"
}


# -------------------------------------

# Setup mariadb server

if flag_is_unset HA || flag_is_set PRIMARY_INSTALL; then

    echo_info "Starting MariaDB server"
    systemctl restart mariadb

    echo_info "Setting up mariadb's root user credentials"
    MYSQL_ROOT_PASSWORD="$(get_password "$MYSQL_ROOT_PASSWORD")"
    setup_root_pass $MYSQL_ROOT_PASSWORD
    store_password MYSQL_ROOT_PASSWORD $MYSQL_ROOT_PASSWORD

    echo_info "Cleaning up test db and anonymous users"
    remove_test_db
    remove_anonymous_users

fi

if flag_is_unset HA; then
    systemctl enable mariadb
else

    echo_info "Stopping MariaDB server; Will be managed via pacemaker"
    systemctl stop mariadb

    # --------------------------------------------------------

    # Update configuration files and the galera resource agent

    echo_info "Updating galera resource-agent and configuration file"

    cp "${POST_FILEDIR}"/galera_agent /usr/lib/ocf/resource.d/heartbeat/galera
    cp "${POST_FILEDIR}"/galera.cnf /etc/my.cnf.d/
    chmod +x /usr/lib/ocf/resource.d/heartbeat/galera

    CLUSTER_ADDR="gcomm://$TRIX_CTRL1_HOSTNAME,$TRIX_CTRL2_HOSTNAME"
    sed -i "s|{{ cluster.addr }}|$CLUSTER_ADDR|" /etc/my.cnf.d/galera.cnf

    if flag_is_set PRIMARY_INSTALL; then

        sed -i "s,{{ node.addr }},$TRIX_CTRL1_IP," /etc/my.cnf.d/galera.cnf
        sed -i "s,{{ node.name }},$TRIX_CTRL1_HOSTNAME," /etc/my.cnf.d/galera.cnf

        # --------------------------------------------------------

        # Create pacemaker resource

        echo_info "Creating and configuring a mariadb resource in pacemaker"

        pcs resource create mariadb galera wsrep_cluster_address="$CLUSTER_ADDR" meta master-max=1 --master
        pcs constraint colocation add Started ClusterIP with Master mariadb-master INFINITY

        echo_info "Bootstrapping the galera cluster"

        crm_attribute -l reboot --name "mariadb-bootstrap" -v "true"

    else
        sed -i "s,{{ node.addr }},$TRIX_CTRL2_IP," /etc/my.cnf.d/galera.cnf
        sed -i "s,{{ node.name }},$TRIX_CTRL2_HOSTNAME," /etc/my.cnf.d/galera.cnf

        pcs resource cleanup mariadb
    fi

    echo "MYSQL_USER=root" > /etc/sysconfig/clustercheck
    echo "MYSQL_PASSWORD=$MYSQL_ROOT_PASSWORD" >> /etc/sysconfig/clustercheck
    chmod 700 /etc/sysconfig/clustercheck

fi
