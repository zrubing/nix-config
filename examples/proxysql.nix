# Example usage for modules/nixos/proxysql/default.nix
#
# 1) Quick start (not secret-safe: passwords end up in the Nix store)
#
# {
#   snowfallorg.proxysql = {
#     enable = true;
#     openFirewall = true;
#
#     admin.credentials = "admin:replace-me";
#
#     mysql.monitor = {
#       username = "monitor";
#       password = "replace-me";
#     };
#
#     mysqlServers = [
#       { address = "10.0.0.11"; port = 3306; hostgroup = 10; }
#       { address = "10.0.0.12"; port = 3306; hostgroup = 20; }
#     ];
#
#     mysqlUsers = [
#       {
#         username = "app";
#         password = "replace-me";
#         defaultHostgroup = 10;
#       }
#     ];
#
#     mysqlQueryRules = [
#       {
#         rule_id = 1;
#         active = true;
#         match_pattern = "^SELECT";
#         destination_hostgroup = 20;
#         apply = true;
#       }
#     ];
#   };
# }
#
# 2) Recommended production pattern with sops.templates
#
# { config, ... }:
# {
#   sops.templates."proxysql.cnf" = {
#     owner = "proxysql";
#     group = "proxysql";
#     mode = "0400";
#     content = ''
#       datadir="/var/lib/proxysql"
#       errorlog="/var/lib/proxysql/proxysql.log"
#
#       admin_variables={
#         admin_credentials="admin:${config.sops.placeholder."proxysql/admin_password"}"
#         mysql_ifaces="0.0.0.0:6032"
#       }
#
#       mysql_variables={
#         interfaces="0.0.0.0:6033"
#         monitor_username="monitor"
#         monitor_password="${config.sops.placeholder."proxysql/monitor_password"}"
#       }
#
#       mysql_servers=(
#         { address="10.0.0.11" port=3306 hostgroup=10 },
#         { address="10.0.0.12" port=3306 hostgroup=20 }
#       )
#
#       mysql_users=(
#         {
#           username="app"
#           password="${config.sops.placeholder."proxysql/app_password"}"
#           default_hostgroup=10
#           active=true
#         }
#       )
#
#       mysql_query_rules=(
#         {
#           rule_id=1
#           active=true
#           match_pattern="^SELECT"
#           destination_hostgroup=20
#           apply=true
#         }
#       )
#     '';
#   };
#
#   snowfallorg.proxysql = {
#     enable = true;
#     openFirewall = true;
#     configFile = config.sops.templates."proxysql.cnf".path;
#   };
# }
