<# ~~~~~~~~~~ MOST IMPORTANT ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Set variable SdtEnableInventory to $True in order to enable inventory system
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ #>
$global:SdtEnableInventory = $false
# --------------------------------------------------------------------------------- #
$global:SdtInventoryInstance = 'InventoryInstance'
$global:SdtInventoryDatabase = 'SQLDBATools'
$global:SdtDbaDatabase = 'DBA'
$global:SdtAutomationDatabase = 'SQLDBATools'
$global:SdtInventoryTable = 'dbo.sdt_server_inventory'
$global:SdtErrorTable = 'dbo.sdt_error'
$global:SdtAlertTable = 'dbo.sdt_alert'
$global:SdtAlertRulesTable = 'dbo.sdt_alert_rules'
$global:SdtLogsPath = $(Join-Path $SdtModulePath 'Logs')
$global:SdtSmtpServer = 'smtp.gmail.com'
$global:SdtSmtpServerPort = 587
$global:SdtUseSsl = $(if($SdtSmtpServer -eq 'smtp.gmail.com'){$true}else{$false})
$global:SdtSmtpGmailUserName = 'yourgmailemailid@gmail.com'
# For more, https://ajaydwivedi.com/2017/09/errorfix-database-mails-using-gmail-getting-unsent-items/
$global:SdtSmtpGmailPassword = 'YouGmailSecretAppPassword'
$global:SdtSmtpGmailCredential= $(New-Object System.Management.Automation.PSCredential ($SdtSmtpGmailUserName, $(ConvertTo-SecureString $SdtSmtpGmailPassword -AsPlainText -Force)));
$global:SdtAlertEmailAddress = 'SQLAlerts@domain.local'
$global:SdtDBAMailId = 'dba@domain.local'
$global:SdtDBAGroupMailId = 'DBAGroup@domain.local'
$global:SdtLogErrorToInventory = $false
$global:SdtPrintUserFriendlyMessage = $false
$global:SdtServiceAccount = "$($env:USERDOMAIN)\SQLDBATools"
$global:SdtSqlServerRepository = '\\itserver\SqlServer\SQL_Server_Setups\'
$global:SdtGrafanaBaseURL = "$($SdtInventoryInstance):3000"
$global:SdtDOP = 4

# Variable Placeholders
$Global:SdtInventoryTableData = @() # data from $SdtInventoryTable. Populated using Get-SdtServers
$Global:SdtServerList = @() # Unique values of [server] from $SdtInventoryTable. Populated using Get-SdtServers
$Global:SdtFriendlyNameList = @() # Unique values of [friendly_name] from $SdtInventoryTable. Populated using Get-SdtServers
$Global:SdtSqlInstanceList = @() # Unique values of [sql_instance] from $SdtInventoryTable. Populated using Get-SdtServers


# Table definition
$global:SdtInventoryTableDefinitionSql= @"
/*
ALTER TABLE $SdtInventoryTable SET ( SYSTEM_VERSIONING = OFF)
go
drop table $SdtInventoryTable
go
drop table $($SdtInventoryTable)_history
go
*/
create table $SdtInventoryTable
( 	server varchar(500) not null, friendly_name varchar(255) not null,
	sql_instance varchar(255) not null,
	ipv4 varchar(15) null, stability varchar(20) default 'DEV',
	server_owner varchar(500) null,
	is_active bit default 1, monitoring_enabled bit default 1
	
	,valid_from DATETIME2 GENERATED ALWAYS AS ROW START HIDDEN NOT NULL
    ,valid_to DATETIME2 GENERATED ALWAYS AS ROW END HIDDEN NOT NULL
    ,PERIOD FOR SYSTEM_TIME (valid_from,valid_to)

	,constraint pk_$($SdtInventoryTable -replace 'dbo.', '') primary key clustered (friendly_name)
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.sdt_server_inventory_history))
go
create unique index uq_$($SdtInventoryTable -replace 'dbo.', '')__server__sql_instance on $SdtInventoryTable (server, sql_instance);
go
create unique index uq_$($SdtInventoryTable -replace 'dbo.', '')__sql_instance on $SdtInventoryTable (sql_instance);
go
create index ix_$($SdtInventoryTable -replace 'dbo.', '')__is_active__monitoring_enabled on $SdtInventoryTable (is_active, monitoring_enabled);
go
alter table $SdtInventoryTable add constraint chk_$($SdtInventoryTable -replace 'dbo.', '')__stability check ( [stability] in ('DEV', 'UAT', 'QA', 'STG', 'PROD', 'PRODDR', 'STGDR','QADR', 'UATDR', 'DEVDR') )
go
"@

# Table definition
$global:SdtErrorTableDefinitionSql= @"
create table $SdtErrorTable
( 	collection_time_utc datetime2 not null default getutcdate(), server varchar(500) null,
    cmdlet varchar(125) not null, command varchar(1000) null, error varchar(500) not null, 
    remark varchar(1000) null
)
go
"@

# Table definition
$global:SdtAlertTableDefinitionSql= @"
create table $SdtAlertTable
(	id bigint identity(1,1) not null,
	created_date_utc datetime2 not null default sysutcdatetime(),
	alert_key varchar(255) not null,
	email_to varchar(500) not null,
	[state] varchar(15) not null default 'Active', -- 'Active','Suppressed','Cleared'
	[severity] varchar(15) not null default 'High', -- 'Critical', 'High', 'Medium', 'Low'
    last_occurred_date_utc datetime not null default getutcdate(),
	last_notified_date_utc datetime not null default getutcdate(),
	notification_counts int not null default 1,
	suppress_start_date_utc datetime null,
	suppress_end_date_utc datetime null,
    servers_affected varchar(1000) null
)
go
alter table $SdtAlertTable add constraint pk_$($SdtAlertTable -replace 'dbo.', '') primary key (id)
go
alter table $SdtAlertTable add constraint chk_$($SdtAlertTable -replace 'dbo.', '')__state check ( [state] in ('Active','Suppressed','Cleared') )
go
alter table $SdtAlertTable add constraint chk_$($SdtAlertTable -replace 'dbo.', '')__severity check ( [severity] in ('Critical', 'High', 'Medium', 'Low') )
go
alter table $SdtAlertTable add constraint chk_$($SdtAlertTable -replace 'dbo.', '')__suppress_state 
	check ( (case	when	[state] <> 'Suppressed'
					then	1
					when	[state] = 'Suppressed'
							and ( suppress_start_date_utc is null or suppress_end_date_utc is null )
					then	0
					when	[state] = 'Suppressed'
							and ( datediff(day,suppress_start_date_utc,suppress_end_date_utc) >= 7 )
					then	0
					else	1
					end) = 1 )
go
--create index ix_$($SdtAlertTable -replace 'dbo.', '')__alert_key__active on $SdtAlertTable (alert_key) where [state] in ('Active','Suppressed')
create unique index uq_$($SdtAlertTable -replace 'dbo.', '')__alert_key__severity__active on $SdtAlertTable (alert_key, severity, email_to) where [state] in ('Active','Suppressed')
go
create index ix_$($SdtAlertTable -replace 'dbo.', '')__created_date_utc__alert_key on $SdtAlertTable (created_date_utc, alert_key)
go
create index ix_$($SdtAlertTable -replace 'dbo.', '')__state__active on $SdtAlertTable ([state]) where [state] in ('Active','Suppressed')
go
create index ix_$($SdtAlertTable -replace 'dbo.', '')__servers_affected on $SdtAlertTable ([servers_affected]);
go
"@

$global:SdtAlertRulesTableDefinitionSql = @"
/*
ALTER TABLE $SdtAlertRulesTable SET ( SYSTEM_VERSIONING = OFF)
go
drop table $SdtAlertRulesTable
go
drop table $($SdtAlertRulesTable)_history
go
*/
create table $SdtAlertRulesTable
(	rule_id bigint identity(1,1) not null,
	alert_key varchar(255) not null,
	server_friendly_name varchar(255) null,
	--server_owner varchar(500) null,
	[database_name] varchar(255) null,
	client_app_name varchar(255) null,
	login_name varchar(125) null,
	client_host_name varchar(255) null,
	severity varchar(15) null,
	severity_low_threshold decimal(5,2) null,
	severity_medium_threshold decimal(5,2) null,
	severity_high_threshold decimal(5,2) null,
	severity_critical_threshold decimal(5,2) null,
	alert_receiver varchar(500) not null,
	alert_receiver_name varchar(120) not null,
	delay_minutes smallint null,
	compute_duration_minutes smallint null,
	[start_date] date null,
	[start_time] time null,
	[end_date] date null,
	[end_time] time null,
	copy_dba bit not null default 1,
	created_by varchar(125) not null default suser_name(),
	created_date_utc datetime not null default getutcdate(),
	reference_request varchar(125) not null,
    is_active bit not null default 1
	
	,valid_from DATETIME2 GENERATED ALWAYS AS ROW START HIDDEN NOT NULL
    ,valid_to DATETIME2 GENERATED ALWAYS AS ROW END HIDDEN NOT NULL
    ,PERIOD FOR SYSTEM_TIME (valid_from,valid_to)

	,constraint pk_$($SdtAlertRulesTable -replace 'dbo.', '')__rule_id primary key clustered (rule_id)
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = $($SdtAlertRulesTable)_history));
go
create unique nonclustered index nci_uq_$($SdtAlertRulesTable -replace 'dbo.', '')__alert_key__plus on $SdtAlertRulesTable 
    (alert_key, server_friendly_name, [database_name], client_app_name, login_name, client_host_name, severity) where is_active = 1;
go
alter table $SdtAlertRulesTable add constraint chk_$($SdtAlertRulesTable -replace 'dbo.', '')__severity check ( [severity] in ('Critical', 'High', 'Medium', 'Low') )
go
--alter table $SdtAlertRulesTable add constraint chk_$($SdtAlertRulesTable -replace 'dbo.', '')__group_by check ( server_friendly_name is null or server_owner is null )
--go
"@

$global:SdtCssStyle= @"
<style>
body {
    color:#333333;
    font-family:Calibri,Tahoma;
    font-size: 10pt;
}
h1 {
    text-align:center;
}
h2 {
    border-top:1px solid #666666;
}
th {
    font-weight:bold;
    color:#eeeeee;
    background-color:#333333;
    cursor:pointer;
}
.odd  { background-color:#ffffff; }
.even { background-color:#dddddd; }
.paginate_enabled_next, .paginate_enabled_previous {
    cursor:pointer; 
    border:1px solid #222222; 
    background-color:#dddddd; 
    padding:2px; 
    margin:4px;
    border-radius:2px;
}
.paginate_disabled_previous, .paginate_disabled_next {
    color:#666666; 
    cursor:pointer;
    background-color:#dddddd; 
    padding:2px; 
    margin:4px;
    border-radius:2px;
}
.dataTables_info { margin-bottom:4px; }
.sectionheader { cursor:pointer; }
.sectionheader:hover { color:red; }
.grid { width:100% }
.red {
    color:red;
    font-weight:bold;
}
.yellow {
    color:yellow;
}
.blue {
    color:blue;
}
</style>
"@

$global:SdtCssStyleBasic= @"
<style>
TABLE {border-width: 1px; border-style: solid; border-color: black; border-collapse: collapse;}
TD {border-width: 1px; padding: 3px; border-style: solid; border-color: black;}
</style>
"@


