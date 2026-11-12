# RMAN configuration 

All databases are configured the same. Preproduction databases use the same VPC user, same ZDLRA as their production databases. Duplication should therefore use a similar configuration.

```
CONFIGURE CHANNEL DEVICE TYPE 'SBT_TAPE' FORMAT   '%d_%I_%U_%T_%t' PARMS  "SBT_LIBRARY=<ORACLE_HOME>/lib/libra.so, ENV=(RA_WALLET='location=file:/var/opt/oracle/dbaas_acfs/<target CDB NAME>/wallet_root/server_seps credential_alias=<alias from wallet, ie ZDLRA connect string>')";
```


# List credentials from wallet

This command gets the alias from above, ZDLRA connection string and VPC user name.

```
$ mkstore -wrl /var/opt/oracle/dbaas_acfs/<target CDB name>/wallet_root/server_seps -listCredential
Oracle Secret Store Tool Release 19.0.0.0.0 - Production
Version 19.32.0.0.0
Copyright (c) 2004, 2026, Oracle and/or its affiliates. All rights reserved.

List credential (index: connect_string username)
2: <ZDLRA Host>:<ZDLRA Port>/<ZDLRA Service> <VPC User name>
```



# Get VPC user password

This command gets the VPC password. 

```
$ mkstore -wrl /var/opt/oracle/dbaas_acfs/<target CDB name>/wallet_root/server_seps -viewEntry oracle.security.client.password2
Oracle Secret Store Tool Release 19.0.0.0.0 - Production
Version 19.32.0.0.0
Copyright (c) 2004, 2026, Oracle and/or its affiliates. All rights reserved.

oracle.security.client.password2 = <password>
```