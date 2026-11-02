#!/bin/sh
# root re-injection watchdog. runs as owner (uid 5001) under systemd --user forever.
# rootd stamps $BASE/rootd.beat with unix time every 10s. /proc/<root pid> is not
# readable from the User context (Smack), so the heartbeat is the only liveness signal.
BASE=/opt/usr/home/owner
LOG=$BASE/rootinject.log
HB=$BASE/rootd.beat

echo "watchdog start pid=$$" >> "$LOG"
[ -e "$HB" ] || { echo 0 > "$HB"; chsmack -a User "$HB" 2>/dev/null; }
echo $$ > "$BASE/rootinject.pid"

# the only call that still spawns uid 0: jpmsd's ExecuteUserShell from the "User"
# context (this watchdog). From the appcmd shell the same call is a no-op.
inject() {
  C=$(printf "\072")
  busctl call com.jackpack.migration /com/jackpack/migration com.jackpack.migration ExecuteUserShell s "0${C}/bin/sh < $BASE/rootd.sh >/dev/null 2>&1 &" >/dev/null 2>&1
  i=0
  while [ $i -lt 15 ]; do
    v=$(cat "$HB" 2>/dev/null)
    now=$(date +%s)
    if [ -n "$v" ] && [ $((now - v)) -lt 12 ]; then return 0; fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

alive() {
  v=$(cat "$HB" 2>/dev/null)
  [ -n "$v" ] || return 1
  [ $(( $(date +%s) - v )) -lt 30 ]
}

while true; do
  if ! alive; then
    if [ ! -e /tmp/rootd.pid ]; then
      # /tmp is tmpfs: no pid file means the first watchdog run after boot
      if inject; then echo "inject boot" >> "$LOG"; else echo "inject boot failed" >> "$LOG"; fi
    else
      # a stale beat right after resume is expected: rootd was frozen too and needs
      # one beat period to stamp again. injecting in that window is what used to
      # break wake-up from standby.
      sleep 12
      if ! alive; then
        if inject; then echo "inject" >> "$LOG"; else echo "inject failed" >> "$LOG"; fi
      fi
    fi
  fi
  sleep 10
done
