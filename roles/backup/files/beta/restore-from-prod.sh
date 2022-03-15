#!/bin/bash

# Script to restore backups from the production server on the beta server (ie:
# synchronize beta with production).

set -e

function usage()
{
	echo "Restore backup from production server to beta server"
	echo "Commands:"
	echo -e "\tprepare-db"
	echo -e "\tstop-website"
	echo -e "\tstop-mysql"
	echo -e "\tbackup-mysql"
	echo -e "\trestore-mysql"
	echo -e "\tstart-mysql"
	echo -e "\tupdate-mysql"
	echo -e "\trestore-data"
	echo -e "\tupdate-zds"
	echo -e "\tstart-website"
	echo -e "\tall (prepare-db, stop-website, stop-mysql, backup-mysql, restore-mysql, start-mysql, update-mysql, restore-data, update-zds, start-website)"
	echo -e "\tclean"
}

function print_info()
{
    if [[ "$2" == "--bold" ]]; then
        echo -en "\033[36;1m"
    else
        echo -en "\033[0;36m"
    fi
    echo "$1"
    echo -en "\033[00m"
}


if [ $# -eq 0 ]
then
	usage;
	exit
fi


prepare_db=0
stop_website=0
stop_mysql=0
backup_mysql=0
restore_mysql=0
start_mysql=0
update_mysql=0
restore_data=0
update_zds=0
start_website=0
clean=0

while [ "$1" != "" ]
do
	case $1 in
		prepare-db )
			prepare_db=1
			;;
		stop-website )
			stop_website=1
			;;
		stop-mysql )
			stop_mysql=1
			;;
		backup-mysql )
			backup_mysql=1
			;;
		restore-mysql )
			restore_mysql=1
			;;
		start-mysql )
			start_mysql=1
			;;
		update-mysql )
			update_mysql=1
			;;
		restore-data )
			restore_data=1
			;;
		update-zds )
			update_zds=1
			;;
		start-website )
			start_website=1
			;;
		clean )
			clean=1
			;;
		all )
			# Everything except "clean":
			prepare_db=1
			stop_website=1
			stop_mysql=1
			backup_mysql=1
			restore_mysql=1
			start_mysql=1
			update_mysql=1
			restore_data=1
			update_zds=1
			start_website=1
			;;
		* )
			echo "Unrecognized option '$1'"
			usage
			exit
			;;
	esac
	shift
done

readonly BACKUP_ROOT=/opt/sauvegarde
readonly BORG_DB=$BACKUP_ROOT/db-borg
readonly BORG_DATA=$BACKUP_ROOT/data
readonly ZDS_ROOT=/opt/zds
readonly ZDS_WRAPPER=$ZDS_ROOT/wrapper
readonly HETRIX_URL_FILE=/root/hetrix-maintenance-url
readonly BACKUP_DB_TMP=/root/db-tmp # rather work on / than /opt/sauvegarde: there is more free space
readonly BACKUP_DB_TMP_FULL=$BACKUP_DB_TMP/var/backups/mysql # rather work on / than /opt/sauvegarde: there is more free space


# Step 1: prepare database backups

if [ $prepare_db -eq 1 -o $restore_mysql -eq 1 ]
then
	if [ ! -e $BACKUP_DB_TMP ]
	then
		print_info "Creating $BACKUP_DB_TMP..."
		mkdir $BACKUP_DB_TMP
		cd $BACKUP_DB_TMP
		print_info "Extracting last database backup with borg..."
		borg list --last 1 $BORG_DB
		borg extract --verbose --progress $BORG_DB::$(borg list --last 1 --format '{archive}{NL}' $BORG_DB)
        fi

	cd $BACKUP_DB_TMP_FULL

	full_backup=""
	incremental_backups_rev=()
	for backup in $(ls -d *-*/ | grep -v .temp | sort -nr)
	do
		if [[ $backup == *-full/ ]]
		then
			full_backup=${backup::-1}
			break;
		else
			incremental_backups_rev+=(${backup::-1})
		fi
	done

	incremental_backups=$(echo "${incremental_backups_rev[@]} " | tac -s ' ')

	echo "Full backup is: $full_backup"
	echo "Incremental backups are: ${incremental_backups[@]}"
fi


if [ $prepare_db -eq 1 ]
then
	print_info "prepare-db" --bold

	print_info "Decompress backups..."
	if [ `tail -n 1 ${full_backup}/mariabackup.log | grep "completed OK!" | wc -l` -eq 0 ]
	then
		echo "Error: the backup ${full_backup} doesn't seem valid"
		exit
        fi
	mkdir ${full_backup}/extracted
	gunzip -c ${full_backup}/backup.stream.gz | mbstream -x -C ${full_backup}/extracted/
	for b in ${incremental_backups[@]}
	do
		if [ `tail -n 1 ${b}/mariabackup.log | grep "completed OK!" | wc -l` -eq 0 ]
		then
			echo "Error: the backup ${b} doesn't seem valid"
			exit
		fi
		mkdir ${b}/extracted
		gunzip -c ${b}/backup.stream.gz | mbstream -x -C ${b}/extracted/
	done

	print_info "Prepare full backup..."
	mariabackup -V --prepare --target-dir ${full_backup}/extracted/
	print_info "Prepare incremental backups..."
	for b in ${incremental_backups[@]}
	do
		mariabackup -V --prepare --target-dir ${full_backup}/extracted/ --incremental-dir ${b}/extracted/
	done
fi



# Step 2: stop the website
if [ $stop_website -eq 1 ]
then
	print_info "stop-website" --bold
	if [ -e $HETRIX_URL_FILE ]
	then
		print_info "Enable maintenance mode in Hetrix..."
		# See https://hetrixtools.com/dashboard/api-explorer/ and "v2 Uptime Maintenance Mode":
		curl $(cat $HETRIX_URL_FILE)3/
		echo
	fi
	cd $ZDS_ROOT/webroot
	print_info "Enable maintenance page..."
	ln -s errors/maintenance.html
	print_info "Stop services..."
	systemctl stop zds
	systemctl stop zds-watchdog
fi

# Stop MySQL and backup its data:
if [ $stop_mysql -eq 1 ]
then
	print_info "stop-mysql" --bold
	systemctl stop mysql
fi
if [ $backup_mysql -eq 1 ]
then
	print_info "backup-mysql" --bold
	mv /var/lib/mysql{,.old}
fi

# Restore database backup:
if [ $restore_mysql -eq 1 ]
then
	print_info "restore-mysql" --bold
	mariabackup -V --copy-back --target-dir $BACKUP_DB_TMP_FULL/${full_backup}/extracted/
	chown -R mysql:mysql /var/lib/mysql
fi

# Start MySQL:
if [ $start_mysql -eq 1 ]
then
	print_info "start-mysql" --bold
	systemctl start mysql
	systemctl status mysql --no-pager
fi

# Update zds' MySQL password:
if [ $update_mysql -eq 1 ]
then
	print_info "update-mysql" --bold
	echo "ALTER USER 'zds'@'localhost' IDENTIFIED BY '$(sed -n '/databases.default/,/^password =/{p;/^password =/q}' /opt/zds/config.toml | tail -n 1 | sed -e 's/.*"\(.*\)"/\1/')'" | mysql
fi

# Restore the website data:
if [ $restore_data -eq 1 ]
then
	print_info "restore-data" --bold
	print_info "Remove $ZDS_ROOT/data..."
	if [ -e $ZDS_ROOT/data ]
	then
		echo "rm -rI $ZDS_ROOT/data..."
		rm -rI $ZDS_ROOT/data # Rather move it, if we have enough space
	fi
	cd / # mandatory for the following borg command
	print_info "Restore backup with borg..."
	borg list --last 1 $BORG_DATA
	borg extract --verbose --progress $BORG_DATA::$(borg list --last 1 --format '{archive}{NL}' $BORG_DATA) opt/zds/data
fi

if [ $update_zds -eq 1 ]
then
	print_info "update-zds" --bold
	print_info "migrate..."
	$ZDS_WRAPPER migrate
	print_info "collectstatic..."
	$ZDS_WRAPPER collectstatic
	print_info "es_manager index_all..."
	$ZDS_WRAPPER es_manager index_all
fi


# Relaunch services:
if [ $start_website -eq 1 ]
then
	print_info "start-website" --bold
	print_info "Start services..."
	systemctl start zds
	systemctl start zds-watchdog
	print_info "Disable maintenance page..."
	rm $ZDS_ROOT/webroot/maintenance.html
	if [ -e $HETRIX_URL_FILE ]
	then
		print_info "Disable maintenance mode in Hetrix..."
		curl $(cat $HETRIX_URL_FILE)1/
		echo
	fi
fi



# Clean everything:
if [ $clean -eq 1 ]
then
	print_info "clean" --bold
	if [ -e /var/lib/mysql.old ]
	then
		echo "rm -rI /var/lib/mysql.old..."
		rm -rI /var/lib/mysql.old
	fi
	if [ -e $BACKUP_DB_TMP ]
	then
		echo "rm -rI $BACKUP_DB_TMP..."
		rm -rI $BACKUP_DB_TMP
        fi
fi
