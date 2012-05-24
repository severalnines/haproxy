#!/bin/bash
TEMPLATE="haproxy.cfg.tmpl"
DC="$1"
SUFFIX="$2"
if ([ -z "$DC" ] || [ -z "$SUFFIX" ]); then
        echo "specify PREFIX and SUFFIX: $0 <prefix> <suffix>; ie: $0 dt 1"
        exit 1
fi
BACKENDFILES=`ls "$DC"_*.backend`
if [ -z "$BACKENDFILES" ]; then
        echo "No backend files found for $DC
                *.backend files are lists of hostnames in files with naming convention  <prefix>_<port>_<name>.backend
                example: dt_9906_production.backend
                the list in the file is seperated by whitespace and each server can optionally have ',disabled' 
                appended to its name to add it as disabled by default.
                example: slave1 slave2,disabled"
        exit 1
fi
NNAME="HAPROXY-$DC$SUFFIX"
NDESC="$NNAME"
if [ ! -f "$TEMPLATE" ]; then
        echo "$TEMPLATE not found!"
        exit 1;
fi
sed -e 's/NODE_NAME/'$NNAME'/g' -e 's/NODE_DESC/'$NDESC'/g'  "$TEMPLATE"
for I in $BACKENDFILES; do
        NAME=`basename $I .backend`
        PORT=`echo $NAME | awk -F'_' '{ print $2 }'`
        DESC=`echo $NAME | sed -e 's/^'$DC'_/'$DC$SUFFIX'_/'`
echo -n "
listen  "$DESC"
        bind *:$PORT
        mode tcp
        timeout client  60000ms
        timeout server  60000ms
        balance leastconn 
        option httpchk
        option allbackups
        default-server port 9200 inter 2s downinter 5s rise 3 fall 2 slowstart 60s maxconn 2048 maxqueue 128 weight 100
	"
        for J in `cat $I`; do
                SPLIT=(`echo $J | tr ',' ' '`);
                STAT=""
                if [ "${SPLIT[1]}" == "disabled" ]; then
                        STAT="disabled"
                fi
                echo -e "\tserver ${SPLIT[0]} ${SPLIT[0]}:3306 check $STAT"
        done
done
exit
