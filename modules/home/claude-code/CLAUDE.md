- 不要过度设计
- 中文回复

## Available Tools

- fd, rg, dnsutils, lsof, gdb, binutils, graphicsmagic (gm)
- On Linux: strace/sysdig/bcc
- pexpect-cli: Persistent pexpect sessions for automating interactive terminal
  applications. Start a session with `pexpect-cli --start`, then send Python
  pexpect code via stdin to control programs. Example:

  ```
  > pexpect-cli --start
  888d9bf4
  > echo 'child = pexpect.spawn("bash"); child.sendline("pwd"); child.expect("$"); print(child.before.decode())' | pexpect-cli 888d9bf4
  ```


## Running programs

- CRITICAL: ALWAYS use pueue for ANY command that might take longer than 10
  seconds to avoid timeouts. 

  To run and wait (note: quote the entire command to preserve argument quoting):
  ```bash
  pueue add -- 'command arg1 "arg with spaces"'
  pueue wait <task-id> && pueue log <task-id>
  ```

