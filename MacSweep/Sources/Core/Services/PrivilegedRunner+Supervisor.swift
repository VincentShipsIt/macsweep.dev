import Foundation

extension PrivilegedRunner {
    /// Builds a pure `/bin/sh` root supervisor. `set -m` gives the trusted command
    /// a PGID equal to its leader PID; the supervisor stays outside that group and
    /// can therefore enforce TERM/grace/KILL even when the app cannot signal root.
    /// Internal shell-construction seam used by lifecycle tests. Entry points
    /// validate `timeout` before calling this helper so elapsed-time conversion
    /// cannot trap on non-finite or out-of-range values.
    static func makeSupervisedShellScript(
        _ script: String,
        keepalivePath: String,
        timeout: TimeInterval,
        timeoutMarker: String
    ) -> String {
        // The keepalive removal enforces the caller's exact monotonic deadline.
        // This longer fallback bounds elevated work if the app crashes first.
        let fallbackSeconds = max(1, Int(ceil(timeout + 2)))
        // Give a live outer supervisor one extra second to remove the keepalive
        // before the anchor treats a full fallback as an orphaned-supervisor path.
        let anchorFallbackSeconds = fallbackSeconds + 1
        let keepalive = shellQuote(keepalivePath)

        return """
            PATH=/usr/bin:/bin:/usr/sbin:/sbin
            export PATH
            umask 077
            state_dir=$(/usr/bin/mktemp -d /private/var/tmp/macsweep-admin.XXXXXX) || exit 125
            trap '/bin/rm -rf "$state_dir"' EXIT
            /bin/chmod 700 "$state_dir" || exit 125
            status_file="$state_dir/status"
            stdout_file="$state_dir/stdout"
            stderr_file="$state_dir/stderr"
            release_file="$state_dir/release"
            cancel_file="$state_dir/cancelled"
            timeout_reader_ready="$state_dir/timeout-reader-ready"
            # Pin both capture inodes before the command starts. Opening them only
            # after cancellation races the anchor's bounded cleanup handoff: a
            # scheduler-delayed outer supervisor can otherwise lose the files before
            # it obtains descriptors, leaving osascript with only the timeout marker.
            /usr/bin/touch "$stdout_file" || exit 125
            /usr/bin/touch "$stderr_file" || exit 125
            exec 3<"$stdout_file" 4<"$stderr_file"
            # macOS /bin/sh provides SECONDS as an elapsed wall-clock counter. Use
            # one origin for every supervisor loop so scheduler-delayed polling can
            # never multiply the intended fallback or release bounds.
            SECONDS=0
            if [ ! -e \(keepalive) ]; then
              /usr/bin/touch "$cancel_file" 2>/dev/null || true
              /usr/bin/printf '%s\n' '\(timeoutMarker)' >&2
              exit 124
            fi
            set -m
            (
              trap '' TERM HUP
              set +m
              terminate_group() {
                wait_for_reader="${1:-yes}"
                /bin/kill -TERM 0 2>/dev/null
                /bin/sleep 0.5
                if [ "$wait_for_reader" = yes ]; then
                  handoff_deadline="$state_dir/timeout-reader-deadline"
                  (
                    trap '' HUP
                    /bin/sleep 1
                    : >"$handoff_deadline"
                  ) </dev/null >/dev/null 2>&1 &
                  while [ -d "$state_dir" ] && [ ! -e "$timeout_reader_ready" ] && [ ! -e "$handoff_deadline" ]; do
                    /bin/sleep 0.1
                  done
                fi
                /bin/rm -rf "$state_dir"
                /bin/kill -KILL 0 2>/dev/null
              }
              (
                trap - TERM HUP
                if [ -e \(keepalive) ]; then
                  (
            \(script)
                  )
                  command_status=$?
                else
                  command_status=124
                fi
                /usr/bin/printf '%s\n' "$command_status" >"$status_file"
                exit "$command_status"
              ) >"$stdout_file" 2>"$stderr_file" &
              while [ ! -s "$status_file" ] && [ -d "$state_dir" ] && [ ! -e "$cancel_file" ] && [ -e \(keepalive) ] && [ "$SECONDS" -lt \(anchorFallbackSeconds) ]; do
                /bin/sleep 0.1
              done
              orphaned_supervisor=no
              if [ "$SECONDS" -ge \(anchorFallbackSeconds) ] && [ -e \(keepalive) ] && [ ! -e "$cancel_file" ]; then
                orphaned_supervisor=yes
              fi
              if [ ! -e \(keepalive) ] || [ "$SECONDS" -ge \(anchorFallbackSeconds) ]; then
                /usr/bin/touch "$cancel_file" 2>/dev/null || true
              fi
              if [ -e "$cancel_file" ] || [ ! -d "$state_dir" ]; then
                if [ "$orphaned_supervisor" = yes ]; then
                  terminate_group no
                else
                  terminate_group yes
                fi
              fi
              if [ -s "$status_file" ]; then
                IFS= read -r command_status <"$status_file"
              else
                command_status=124
              fi
              while [ ! -e "$release_file" ] && [ -d "$state_dir" ] && [ -e \(keepalive) ] && [ "$SECONDS" -lt \(anchorFallbackSeconds) ]; do
                /bin/sleep 0.1
              done
              if [ ! -e "$release_file" ]; then
                terminate_group
              fi
              exit "$command_status"
            ) 3<&- 4<&- &
            anchor_pid=$!
            set +m
            while [ ! -s "$status_file" ] && [ ! -e "$cancel_file" ] && [ -e \(keepalive) ] && [ "$SECONDS" -lt \(fallbackSeconds) ]; do
              /bin/sleep 0.1
            done
            if [ -e "$cancel_file" ] || [ ! -e \(keepalive) ] || [ "$SECONDS" -ge \(fallbackSeconds) ]; then
              /usr/bin/touch "$cancel_file" 2>/dev/null || true
              # The descriptors were pinned before launch, so the anchor may unlink
              # its private state as soon as it observes this handoff without racing
              # away the captured bytes.
              /usr/bin/touch "$timeout_reader_ready" 2>/dev/null || true
              # The anchor kills its own job group, and some shells print the entire
              # terminated subshell at wait. Keep that diagnostic out of the captured
              # privileged-command payload while synchronizing on anchor completion.
              wait "$anchor_pid" 2>/dev/null || true
              /bin/cat <&3 >&2
              /bin/cat <&4 >&2
              /usr/bin/printf '%s\n' '\(timeoutMarker)' >&2
              exit 124
            fi
            if [ -s "$status_file" ]; then
              IFS= read -r command_status <"$status_file"
              /usr/bin/touch "$release_file" 2>/dev/null || true
              /bin/cat "$stdout_file"
              /bin/cat "$stderr_file" >&2
              exit "${command_status:-1}"
            fi
            /usr/bin/printf '%s\n' 'Supervisor state error' >&2
            exit 125
            """
    }

}
