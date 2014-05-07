#!/bin/bash

#!/bin/bash

LOGLEVEL=$LOGLEVEL_DEBUG

. $(dirname $(readlink -f $0))/../lib/bash/softec-common.sh || exit

#echo -e "\nSome info based on my default variables:\n"
#echo -e "Hello I'm '$SCRIPTNAME' running from '$SCRIPTPATH'\n, you can call me shortly '$SHORTNAME'\n"
#echo -e "I can log in '$LOGFILE', I have a cache dir in '$CACHEDIR', if needed\n"
#echo -e "My config come from '$CONFDIR/$CONFFILENAME'\n"
#echo -e "If I send mail, the sender is '$MAILFROM' and I write to '$MAILTO'\n"
#
#echo -e "The default LOGLEVEL is normal ($LOGLEVEL_NORMAL), but I set it to "
#echo -e "debug ($LOGLEVEL_DEBUG) to be more verbose\n"

# Load configuration from default path
# call with a parameter to get a specific config file
include_conf

# set a lockfile... at the end of the script call unlock
get_lock

# Questa funzione viene chiamata in caso di CTRL-C
# Viene inoltre chiamata esplicitamente nella quit
# per fare la stessa pulizia in caso di uscita normale
# 
function clean()
{
    rm -f $CACHEDIR/*
}

# Classica funzione che spiega la sintassi
function help()
{
    echo -e "Usage: `basename $0` --action=<action> [OPTIONS]\n
    `basename $0` manage upload of solr config on zookeeper

    OPTIONS:
    -a|--action:\t action to perform. Available value are <upconfig|delete|check|checkconfigs|getcollections|listconfig>
    \t\t\t - upconfig:      upload configuration files present in --confdir using name declared in --confname
    \t\t\t - delete:        delete configuration specified in --confname
    \t\t\t - check:         exit with 0 if configuration specified in --confname exists. Exit with 0 otherwise
    \t\t\t - checkconfigs:  compare conf files present in --confdir with config file already uploaded and named as --confname.
    \t\t\t - getcollections:return a list of presents collections
    \t\t\t - listconfig:    return a list of presents configs

    --confdir:\t\t directory containing collection's xml configuration files that will be checked
    --confname:\t\t name for the config that will be uploaded or checked.
    --noout:\t\t suppress information output
    -d|--debug:\t\t enable debug mode
    -h|--help:\t\t print this help and exit\n\n"
    exit 0
}
# Funzione chiamata alla fine dello script
# restituisce 0 a meno che non gli si passi
# un valore come primo parametro
function clean()
{
    unlock
}

# i : all'inizio della stringa di options servono
#     a gestire l'errore esplicitamente in caso di
#     invio di parametri non previsti, infatti
#     il valore di OPT diventa ? e OPTARG prende
#     il valore del parametro non previsto
# i : DOPO un parametro previsto significano invece
#     che il parametro richiede un argomento

NOOUT=0
CONFNAME=''
CONFDIR=''
DEBUG=0

TEMP=`getopt -o :a:w:c:s:dh --long action:,confname:,confdir:,debug,noout,help,listconfig -n "$0" -- "$@"`
if [ $? != 0 ] ; then echo "Terminating..." >&2 ; exit 1 ; fi
# Note the quotes around `$TEMP': they are essential!
eval set -- "$TEMP"

while true; do
  case "$1" in
    -d | --debug )
        DEBUG=1
        setloglevel 3
        shift 1
        ;;
    -a | --action )
        if [ $2 != 'upconfig' ] && [ $2 != 'delete' ] && [ $2 != 'check' ] && [ $2 != 'checkconfigs' ] && [ $2 != 'getcollections' ] && [ $2 != 'listconfig' ]; then
            log_error "Error: undefined action $2"
            exit 1
        else
            ACTION=$2
        fi
        shift 2
        ;;
    --confname )
        CONFNAME=$2
        shift 2
        ;;
    --confdir )
        CONFDIR=$2
        shift 2
        ;;
    --getcollections )
        shift 2
        ;;
    --listconfig )
        shift 2
        ;;
    --noout )
        NOOUT=1
        shift 2
        ;;
    -h | --help)
        help
        exit
        shift 2
        ;;
    -- ) shift; break ;;
    * ) break ;;
  esac
done
ZOOKEEPER_ADDRESS=''
#ordina casualmente l'array con gli indirizzi dei nodi zookeeper, partendo dal primo prova a fare nmap, il primo che risponde viene utilizzato per fare le query
RANDOM_INDEX=`shuf --input-range=0-$(( ${#ZOOKEEPERS[*]} - 1 ))`
for index in $RANDOM_INDEX
do
    if [ "x$ZOOKEEPER_ADDRESS" == "x" ]; then
        ZOOKEEPER_ADDRESS=${ZOOKEEPERS[$index]}
        ADDRESS=`echo $ZOOKEEPER_ADDRESS | cut -d: -f1`
        PORT=`echo $ZOOKEEPER_ADDRESS | cut -d: -f2`
        log_debug "trying to reach ${ADDRESS}:${PORT}"
        port_state=`nmap -p$PORT $ADDRESS | grep "$PORT/tcp" | awk '{print $2}'`
        if [ "x$port_state" == "xopen" ]; then
            if [ $NOOUT -eq 0 ]; then
                log_debug "zookeeper $ADDRESS:$PORT will be used"
            fi
        else
            log_debug "status: $port_state, skip to next address"
        fi
    fi
done

if [ "x$ZOOKEEPER_ADDRESS" == "x" ]; then
    log_error "none of zookeeper nodes is reachable"
    exit 1
fi

case $ACTION in
    check )
        if [ "x${CONFNAME}" == "x" ]; then
            log_error "--confname is mandatory in --action=check"
            exit 1
        fi
        ${ZKCLI} -z ${ZOOKEEPER_ADDRESS}/${CLUSTER}/configs/${CONFNAME} -cmd list > /dev/null 2>&1
        exit $?
        ;;
    checkconfigs)
        if [ "x${CONFNAME}" == "x" ] || [ "x${CONFDIR}" == "x" ]; then
            log_error "--confname and --condfir are mandatory in --action=checkconfigs"
            exit 1
        fi
        tmp_confdir=`mktemp -d`
        log_debug "download ${CONFNAME} in $tmp_confdir"
        ${ZKCLI} -z ${ZOOKEEPER_ADDRESS}/${CLUSTER} -confname ${CONFNAME} -confdir $tmp_confdir -cmd downconfig 2> /dev/null
        diff=`diff -r -q -x '.svn' -x '.git' $tmp_confdir $CONFDIR`
        exit_status=$?
        if [ $exit_status -eq 0 ]; then
            log "configs are equal"
        else
            log "configs are different"
        fi
        exit $exit_status
        ;;
    upconfig)
        if [ "x${CONFNAME}" == "x" ] || [ "x${CONFDIR}" == "x" ]; then
            log_error "--confname and --condfir are mandatory in --action=upconfig"
            exit 1
        fi
        log_debug "upload di $CONFIDIR per conf $CONFNAME"
        $ZKCLI -z ${ZOOKEEPER_ADDRESS}/${CLUSTER} -confdir $CONFDIR -confname $CONFNAME -cmd upconfig 2> /dev/null
        if [ $? -eq 0 ]; then
            log "config uploaded successfully to zookeeper"
            log_debug "config in $CONFDIR successfully uploaded to ${ZOOKEEPER_ADDRESS}/${CLUSTER}/configs/${CONFNAME}"
            exit 0
        else
            log_error "error uploading config $CONFDIR to ${ZOOKEEPER_ADDRESS}/${CLUSTER}/configs/${CONFNAME}.\n$ZKCLI -z ${ZOOKEEPER_ADDRESS}/${CLUSTER} -confdir $CONFDIR -confname $CONFNAME -cmd upconfig"
            exit 1
        fi
        ;;
    getcollections)
        COLLECTIONS=`$ZKCLI -z ${ZOOKEEPER_ADDRESS}/${CLUSTER} -cmd list /collections/ 2> /dev/null | egrep '/collections/[^/]*$' | cut -d/ -f 3 | cut -d' ' -f1`
        echo $COLLECTIONS | sed -e s'/\ /\n/'
        exit 0
        ;;
    listconfig)
        CONFIGS=`$ZKCLI -z ${ZOOKEEPER_ADDRESS}/${CLUSTER} -cmd list /configs/ 2> /dev/null | egrep '/configs/[^/]*$' | cut -d/ -f 3 | cut -d' ' -f1`
        #echo $CONFIGS
        echo $CONFIGS | sed -e s'/\ /\n/'
        exit 0
        ;;
    * )
        log_error "no action defined"
        exit 1
        ;;
esac
