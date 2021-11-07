<# ~~~~~~~~~~ MOST IMPORTANT ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Set variable SdtEnableInventoryFeasture to $True in order to enable inventory system
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ #>
Set-Variable -Name SdtEnableInventory -Value $false -Scope Global;
# --------------------------------------------------------------------------------- #
Set-Variable -Name SdtInventoryInstance -Value 'InventoryInstance' -Scope Global;
Set-Variable -Name SdtInventoryDatabase -Value 'SQLDBATools' -Scope Global;
Set-Variable -Name SdtDbaDatabase -Value 'DBA' -Scope Global;
Set-Variable -Name SdtAutomationDatabase -Value 'SQLDBATools' -Scope Global;
Set-Variable -Name SdtInventoryTable -Value 'dbo.sdt_server_inventory' -Scope Global;
Set-Variable -Name SdtErrorTable -Value 'dbo.sdt_error' -Scope Global;
Set-Variable -Name SdtAlertTable -Value 'dbo.sdt_alert' -Scope Global;
Set-Variable -Name SdtLogsPath -Value $(Join-Path $SdtModulePath 'Logs') -Scope Global;
Set-Variable -Name SdtSmtpServer -Value 'mail.domain.local' -Scope Global;
Set-Variable -Name SdtAlertEmailAddress -Value 'SQLAlerts@domain.local' -Scope Global;
Set-Variable -Name SdtSmtpServerPort -Value 25 -Scope Global;
Set-Variable -Name SdtDBAMailId -Value 'dba@domain.local' -Scope Global;
Set-Variable -Name SdtDBAGroupMailId -Value 'DBAGroup@domain.local' -Scope Global;
Set-Variable -Name SdtLogErrorToInventory -Value $false -Scope Global;
Set-Variable -Name SdtPrintUserFriendlyMessage -Value $false -Scope Global;
Set-Variable -Name SdtServiceAccount -Value "$($env:USERDOMAIN)\SQLDBATools" -Scope Global;
Set-Variable -Name SdtSqlServerRepository -Value 'itserver\SqlServer\SQL_Server_Setups\' -Scope Global;
Set-Variable -Name SdtGrafanaBaseURL -Value "$($SdtInventoryInstance):3000" -Scope Global;
Set-Variable -Name SdtDOP -Value 4 -Scope Global;

# Variable Placeholders
$Global:SdtServers = @() # servers from inventory to be populated by function Get-SdtServers
$Global:SdtServersFriendlyName = @() # servers from inventory to be populated by function Get-SdtServers
$Global:SdtServersList = @() # servers from inventory to be populated by function Get-SdtServers

# Table definition
Set-Variable -Name SdtInventoryTableDefinitionSql -Scope Global -Value @"
create table $SdtInventoryTable
( 	server varchar(500) not null, friendly_name varchar(255) not null, 
	ipv4 varchar(15) null, stability varchar(20) default 'DEV', 
	is_active bit default 1, monitoring_enabled bit default 1
)
go
alter table $SdtInventoryTable add constraint pk_$($SdtInventoryTable -replace 'dbo.', '') primary key (friendly_name);
go
create unique index uq_$($SdtInventoryTable -replace 'dbo.', '')__server on $SdtInventoryTable (server);
go
create index ix_$($SdtInventoryTable -replace 'dbo.', '')__is_active__monitoring_enabled on $SdtInventoryTable (is_active, monitoring_enabled);
go
alter table $SdtInventoryTable add constraint chk_$($SdtInventoryTable -replace 'dbo.', '')__stability check ( [stability] in ('DEV', 'UAT', 'QA', 'STG', 'PROD', 'PRODDR', 'STGDR','QADR', 'UATDR', 'DEVDR') )
go
"@

# Table definition
Set-Variable -Name SdtErrorTableDefinitionSql -Scope Global -Value @"
create table $SdtErrorTable
( 	collection_time_utc datetime2 not null default getutcdate(), server varchar(500) null,
    cmdlet varchar(125) not null, command varchar(1000) null, error varchar(500) not null, 
    remark varchar(1000) null
)
go
"@

# Table definition
Set-Variable -Name SdtAlertTableDefinitionSql -Scope Global -Value @"
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
	suppress_end_date_utc datetime null
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
create unique index uq_$($SdtAlertTable -replace 'dbo.', '')__alert_key__active on $SdtAlertTable (alert_key) where [state] in ('Active','Suppressed')
go
create index ix_$($SdtAlertTable -replace 'dbo.', '')__created_date_utc__alert_key on $SdtAlertTable (created_date_utc, alert_key)
go
create index ix_$($SdtAlertTable -replace 'dbo.', '')__state__active on $SdtAlertTable ([state]) where [state] in ('Active','Suppressed')
go
"@

Set-Variable -Name SdtCssStyle -Scope Global -Value @"
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

Set-Variable -Name SdtCssStyleBasic -Scope Global -Value @"
<style>
TABLE {border-width: 1px; border-style: solid; border-color: black; border-collapse: collapse;}
TD {border-width: 1px; padding: 3px; border-style: solid; border-color: black;}
</style>
"@


