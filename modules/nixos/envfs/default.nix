{

  lib,
  pkgs,
  ...

}:
{

  services.envfs.enable = true;

  # stable nixpkgs 当前打包的是 envfs 1.1.0（2025-03-26），有上游 fuse 死锁：
  # 解析 /usr/bin/<name> 时会按请求进程的 PATH 做 access()，若 PATH 上有指回
  # envfs 自身的符号链接，就变成 envfs 等 envfs；daemon 单线程，卡死后所有
  # /bin、/usr/bin 访问永久阻塞，只能 umount + kill 恢复。
  # 见 https://github.com/Mic92/envfs/issues/196
  #
  # 1.2.0 修了两处：
  #   - PR #214：符号链接一律解析到 envfs 挂载点之外，消除自引用死锁
  #   - PR #216：前台进程等文件系统就绪再退出，消除开机
  #     "Mount process finished, but there is no mount" 竞态
  services.envfs.package = pkgs.unstable.envfs;
}
