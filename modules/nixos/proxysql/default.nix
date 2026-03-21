{
  config,
  lib,
  namespace,
  pkgs,
  ...
}:
let
  inherit (lib)
    attrNames
    concatMapStringsSep
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    optionalString
    optionals
    literalExpression
    types
    ;

  cfg = config.${namespace}.proxysql;

  escapeString = value:
    builtins.replaceStrings [ "\\" "\"" "\n" ] [ "\\\\" "\\\"" "\\n" ] (toString value);

  renderScalar = value:
    let
      valueType = builtins.typeOf value;
    in
    if valueType == "bool" then
      if value then "true" else "false"
    else if valueType == "int" || valueType == "float" then
      toString value
    else if valueType == "string" || valueType == "path" then
      ''"${escapeString value}"''
    else
      throw "Unsupported ProxySQL scalar value of type ${valueType}";

  renderValue = indent: value:
    let
      valueType = builtins.typeOf value;
    in
    if valueType == "set" then
      renderGroup indent value
    else if valueType == "list" then
      renderList indent value
    else
      renderScalar value;

  renderSetting = indent: name: value: ''${indent}${name}=${renderValue indent value}'';

  renderGroup = indent: attrs:
    if attrs == { } then
      "{}"
    else
      let
        childIndent = indent + "  ";
        body = concatMapStringsSep "\n" (name: renderSetting childIndent name attrs.${name}) (attrNames attrs);
      in
      ''{
${body}
${indent}}'';

  renderList = indent: values:
    if values == [ ] then
      "()"
    else
      let
        childIndent = indent + "  ";
        body = concatMapStringsSep ",\n" (value: ''${childIndent}${renderValue childIndent value}'') values;
      in
      ''(
${body}
${indent})'';

  pruneNulls = attrs:
    builtins.removeAttrs attrs (
      builtins.filter (name: attrs.${name} == null) (attrNames attrs)
    );

  mysqlServers = map
    (server:
      pruneNulls {
        inherit (server) address port hostgroup status weight compression comment;
        max_connections = server.maxConnections;
        max_replication_lag = server.maxReplicationLag;
      }
    )
    cfg.mysqlServers;

  mysqlUsers = map
    (user:
      pruneNulls {
        inherit (user) username password comment;
        default_hostgroup = user.defaultHostgroup;
        active = user.active;
        max_connections = user.maxConnections;
        default_schema = user.defaultSchema;
        transaction_persistent = user.transactionPersistent;
        fast_forward = user.fastForward;
        frontend = user.frontend;
        backend = user.backend;
      }
    )
    cfg.mysqlUsers;

  generatedSettings =
    {
      datadir = cfg.dataDir;
      errorlog = "${cfg.dataDir}/proxysql.log";

      admin_variables = {
        admin_credentials = cfg.admin.credentials;
        mysql_ifaces = "${cfg.admin.bindAddress}:${toString cfg.admin.port}";
      } // cfg.admin.extraConfig;

      mysql_variables = {
        threads = cfg.mysql.threads;
        max_connections = cfg.mysql.maxConnections;
        default_query_delay = 0;
        default_query_timeout = 36000000;
        have_compress = true;
        poll_timeout = 2000;
        interfaces = "${cfg.mysql.bindAddress}:${toString cfg.mysql.port}";
        default_schema = cfg.mysql.defaultSchema;
        stacksize = 1048576;
        server_version = cfg.mysql.serverVersion;
        connect_timeout_server = cfg.mysql.connectTimeoutServer;
        monitor_username = cfg.mysql.monitor.username;
        monitor_password = cfg.mysql.monitor.password;
        monitor_history = 600000;
        monitor_connect_interval = 60000;
        monitor_ping_interval = 10000;
        monitor_read_only_interval = 1500;
        monitor_read_only_timeout = 500;
        ping_interval_server_msec = 120000;
        ping_timeout_server = 500;
        commands_stats = true;
        sessions_sort = true;
        connect_retries_on_failure = 10;
      } // cfg.mysql.extraConfig;

      mysql_servers = mysqlServers;
      mysql_users = mysqlUsers;
      mysql_query_rules = cfg.mysqlQueryRules;
      scheduler = cfg.scheduler;
      mysql_replication_hostgroups = cfg.mysqlReplicationHostgroups;
    }
    // cfg.extraConfig;

  generatedConfigText = ''
# Managed by NixOS (${namespace}.proxysql)
# NOTE: ProxySQL normally persists runtime config into ${cfg.dataDir}/proxysql.db.
# This module defaults to deleting that database on each start so the Nix config
# remains the source of truth.
${concatMapStringsSep "\n\n" (name: renderSetting "" name generatedSettings.${name}) (attrNames generatedSettings)}
'';

  configFilePath =
    if cfg.configFile != null then
      cfg.configFile
    else
      pkgs.writeText "proxysql.cnf" generatedConfigText;
in
{
  options.${namespace}.proxysql = {
    enable = mkEnableOption "ProxySQL";

    package = mkOption {
      type = types.package;
      default = pkgs.proxysql;
      defaultText = literalExpression "pkgs.proxysql";
      description = "ProxySQL package to run.";
    };

    configFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = literalExpression ''config.sops.templates."proxysql.cnf".path'';
      description = ''
        Optional external ProxySQL config file. When set, the module uses this file
        directly instead of generating one in the Nix store. This is the preferred
        approach when the config contains real passwords.
      '';
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/proxysql";
      description = "ProxySQL data directory.";
    };

    user = mkOption {
      type = types.str;
      default = "proxysql";
      description = "System user that runs ProxySQL.";
    };

    group = mkOption {
      type = types.str;
      default = "proxysql";
      description = "System group that runs ProxySQL.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open the ProxySQL admin and MySQL listener ports in the firewall.";
    };

    reinitializeDatabaseOnStart = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Delete ${cfg.dataDir}/proxysql.db before each start so the declarative Nix
        configuration is reapplied every time. Disable this if you want ProxySQL's
        on-disk runtime database to survive restarts.
      '';
    };

    admin = {
      bindAddress = mkOption {
        type = types.str;
        default = "0.0.0.0";
        description = "Bind address for the ProxySQL admin interface.";
      };

      port = mkOption {
        type = types.port;
        default = 6032;
        description = "TCP port for the ProxySQL admin interface.";
      };

      credentials = mkOption {
        type = types.str;
        default = "admin:admin";
        description = ''
          Value for admin_variables.admin_credentials.
          Avoid using this option for production secrets unless you intentionally accept
          the credentials being stored in the Nix store. Prefer configFile + sops/agenix.
        '';
      };

      extraConfig = mkOption {
        type = types.attrsOf types.anything;
        default = { };
        description = "Extra entries merged into admin_variables.";
      };
    };

    mysql = {
      bindAddress = mkOption {
        type = types.str;
        default = "0.0.0.0";
        description = "Bind address for the MySQL listener.";
      };

      port = mkOption {
        type = types.port;
        default = 6033;
        description = "TCP port for the MySQL listener.";
      };

      threads = mkOption {
        type = types.int;
        default = 4;
        description = "Value for mysql_variables.threads.";
      };

      maxConnections = mkOption {
        type = types.int;
        default = 2048;
        description = "Value for mysql_variables.max_connections.";
      };

      defaultSchema = mkOption {
        type = types.str;
        default = "information_schema";
        description = "Default schema exposed by ProxySQL.";
      };

      serverVersion = mkOption {
        type = types.str;
        default = "8.0.36";
        description = "Server version announced by ProxySQL to clients.";
      };

      connectTimeoutServer = mkOption {
        type = types.int;
        default = 3000;
        description = "Value for mysql_variables.connect_timeout_server.";
      };

      monitor = {
        username = mkOption {
          type = types.str;
          default = "monitor";
          description = "Username used by ProxySQL monitor.";
        };

        password = mkOption {
          type = types.str;
          default = "monitor";
          description = ''
            Password used by ProxySQL monitor.
            Avoid storing real secrets here in production. Prefer configFile + sops/agenix.
          '';
        };
      };

      extraConfig = mkOption {
        type = types.attrsOf types.anything;
        default = { };
        description = "Extra entries merged into mysql_variables.";
      };
    };

    mysqlServers = mkOption {
      type = types.listOf (types.submodule ({ ... }: {
        options = {
          address = mkOption {
            type = types.str;
            description = "Backend MySQL address or socket path.";
          };
          port = mkOption {
            type = types.int;
            default = 3306;
            description = "Backend MySQL port. Use 0 for Unix sockets.";
          };
          hostgroup = mkOption {
            type = types.int;
            description = "ProxySQL hostgroup id.";
          };
          status = mkOption {
            type = types.str;
            default = "ONLINE";
            description = "Backend status.";
          };
          weight = mkOption {
            type = types.int;
            default = 1;
            description = "Backend weight.";
          };
          compression = mkOption {
            type = types.int;
            default = 0;
            description = "Compression flag.";
          };
          maxConnections = mkOption {
            type = types.nullOr types.int;
            default = null;
            description = "Optional max_connections override for the backend.";
          };
          maxReplicationLag = mkOption {
            type = types.nullOr types.int;
            default = null;
            description = "Optional max_replication_lag override.";
          };
          comment = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Optional comment.";
          };
        };
      }));
      default = [ ];
      description = "List of mysql_servers entries.";
    };

    mysqlUsers = mkOption {
      type = types.listOf (types.submodule ({ ... }: {
        options = {
          username = mkOption {
            type = types.str;
            description = "Frontend username exposed by ProxySQL.";
          };
          password = mkOption {
            type = types.str;
            description = ''
              Frontend password exposed by ProxySQL.
              Avoid storing real secrets here in production. Prefer configFile + sops/agenix.
            '';
          };
          defaultHostgroup = mkOption {
            type = types.int;
            default = 0;
            description = "Default backend hostgroup for the user.";
          };
          active = mkOption {
            type = types.bool;
            default = true;
            description = "Whether the user is active.";
          };
          maxConnections = mkOption {
            type = types.nullOr types.int;
            default = null;
            description = "Optional max_connections override for the user.";
          };
          defaultSchema = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Optional default schema for the user.";
          };
          transactionPersistent = mkOption {
            type = types.nullOr types.bool;
            default = null;
            description = "Optional transaction_persistent flag.";
          };
          fastForward = mkOption {
            type = types.nullOr types.bool;
            default = null;
            description = "Optional fast_forward flag.";
          };
          frontend = mkOption {
            type = types.nullOr types.bool;
            default = null;
            description = "Optional frontend flag.";
          };
          backend = mkOption {
            type = types.nullOr types.bool;
            default = null;
            description = "Optional backend flag.";
          };
          comment = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Optional comment.";
          };
        };
      }));
      default = [ ];
      description = "List of mysql_users entries.";
    };

    mysqlQueryRules = mkOption {
      type = types.listOf (types.attrsOf types.anything);
      default = [ ];
      description = "Raw mysql_query_rules entries.";
    };

    mysqlReplicationHostgroups = mkOption {
      type = types.listOf (types.attrsOf types.anything);
      default = [ ];
      description = "Raw mysql_replication_hostgroups entries.";
    };

    scheduler = mkOption {
      type = types.listOf (types.attrsOf types.anything);
      default = [ ];
      description = "Raw scheduler entries.";
    };

    extraConfig = mkOption {
      type = types.attrsOf types.anything;
      default = { };
      description = "Extra top-level ProxySQL config entries.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = cfg.admin.port != cfg.mysql.port;
          message = "${namespace}.proxysql.admin.port and ${namespace}.proxysql.mysql.port must be different.";
        }
      ];

      warnings = optionals (cfg.configFile == null && (
        cfg.admin.credentials == "admin:admin"
        || cfg.mysql.monitor.password == "monitor"
      )) [
        "${namespace}.proxysql is using default credentials. Replace them before exposing the service."
      ];

      users.groups.${cfg.group} = { };
      users.users.${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
        home = cfg.dataDir;
        createHome = false;
        description = "ProxySQL service user";
      };

      environment.systemPackages = [ cfg.package ];

      networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [
        cfg.admin.port
        cfg.mysql.port
      ];

      systemd.services.proxysql = {
        description = "ProxySQL";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        restartTriggers = [ configFilePath ];

        preStart = ''
          install -d -m 0750 -o ${cfg.user} -g ${cfg.group} ${cfg.dataDir}
          rm -f ${cfg.dataDir}/proxysql.pid
          ${optionalString cfg.reinitializeDatabaseOnStart ''
          rm -f ${cfg.dataDir}/proxysql.db
          rm -f ${cfg.dataDir}/proxysql_stats.db
          ''}
        '';

        serviceConfig = {
          Type = "forking";
          User = cfg.user;
          Group = cfg.group;
          PermissionsStartOnly = true;
          RuntimeDirectory = "proxysql";
          RuntimeDirectoryMode = "0750";
          PIDFile = "${cfg.dataDir}/proxysql.pid";
          ExecStart = "${cfg.package}/bin/proxysql --idle-threads -c ${configFilePath} -D ${cfg.dataDir}";
          Restart = "on-failure";
          UMask = "0007";
          LimitNOFILE = 102400;
          LimitCORE = 1073741824;
          ProtectHome = true;
          NoNewPrivileges = true;
          CapabilityBoundingSet = [ "CAP_SETGID" "CAP_SETUID" "CAP_SYS_RESOURCE" ];
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_ALG" ];
          ProtectSystem = "full";
          # Allow missing path during namespace setup; preStart creates it before proxysql starts.
          ReadWritePaths = [ "-${cfg.dataDir}" ];
          PrivateDevices = true;
          # Keep preStart runnable on first boot even if dataDir is not created yet.
          WorkingDirectory = "/";
        };
      };
    }
  ]);
}
