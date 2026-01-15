- 不要过度设计
- 中文回复

## Available Tools

- fd, rg, dnsutils, lsof, gdb, binutils, graphicsmagic (gm)
- On Linux: strace/sysdig/bcc

## Running programs

- CRITICAL: ALWAYS use pueue for ANY command that might take longer than 10
  seconds to avoid timeouts. 

  To run and wait (note: quote the entire command to preserve argument quoting):
  ```bash
  pueue add -- 'command arg1 "arg with spaces"'
  pueue wait <task-id> && pueue log <task-id>
  ```

