Set-StrictMode -Version Latest

function Add-PdaProperty {
    param($Object, [string]$Name, $Value)
    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
        return $true
    }
    return $false
}

function Set-PdaProperty {
    param($Object, [string]$Name, $Value)
    if ($null -eq $Object.PSObject.Properties[$Name]) { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
    else { $Object.$Name = $Value }
}

function Initialize-PdaConsoleSchema {
    param($Store, [string]$DataRoot)
    $changed = $false
    foreach ($pair in @(
        @('projects', @()), @('emails', @()), @('knowledgePermissions', @()),
        @('permissionEvents', @()), @('knowledgeAccessEvents', @())
    )) { if (Add-PdaProperty $Store $pair[0] $pair[1]) { $changed = $true } }
    foreach ($pair in @(
        @('workspaceName', '个人助理'), @('setupCompleted', $true),
        @('dingtalkAiTag', [bool]$Store.config.aiLabelEnabled)
    )) { if (Add-PdaProperty $Store.config $pair[0] $pair[1]) { $changed = $true } }
    foreach ($item in @($Store.whitelist)) {
        foreach ($pair in @(
            @('user_id', [string]$item.identity), @('open_id', ''), @('notes', ''), @('enabled', $true),
            @('human_reply_guard_enabled', $true), @('permission_role', 'colleague'),
            @('allow_private_knowledge', $false), @('allowed_categories', @('general','project','schedule','technical')),
            @('denied_categories', @()), @('allowed_projects', @()), @('custom_reply_rules', ''),
            @('permission_events', @()), @('knowledge_access_events', @())
        )) { if (Add-PdaProperty $item $pair[0] $pair[1]) { $changed = $true } }
    }
    if ($changed) { Write-PdaStore $Store $DataRoot }
    return $Store
}

function Get-PdaRelativePath {
    param([string]$Root, [string]$Path)
    $rootUri = [Uri](([IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'))
    return [Uri]::UnescapeDataString($rootUri.MakeRelativeUri([Uri][IO.Path]::GetFullPath($Path)).ToString()).Replace('/', '\')
}

function Get-PdaDocumentId {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').Substring(0, 24).ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-PdaKnowledgeCategory {
    param([string]$RelativePath, [string]$Content)
    $text = "$RelativePath $Content"
    if ($text -match '排期|里程碑|计划|节点|阶段') { return 'schedule' }
    if ($text -match '项目|Q\d{2,}') { return 'project' }
    if ($text -match '技术|设计|规格|传感器|算法|接口') { return 'technical' }
    if ($text -match '财务|合同|薪资|人事') { return 'sensitive' }
    return 'general'
}

function Get-PdaKnowledgeDocuments {
    param($Store, [string]$DataRoot)
    $root = Get-PdaDataRoot $DataRoot
    $knowledgeRoot = Join-Path $root '知识库'
    if (-not (Test-Path -LiteralPath $knowledgeRoot)) { return @() }
    $documents = @()
    foreach ($file in Get-ChildItem -LiteralPath $knowledgeRoot -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue) {
        $relative = Get-PdaRelativePath $root $file.FullName
        $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        $title = ([regex]::Match($content, '(?m)^#\s+(.+)$')).Groups[1].Value.Trim()
        if (-not $title) { $title = $file.BaseName }
        $rule = @($Store.knowledgePermissions | Where-Object path -eq $relative | Select-Object -First 1)
        $visibility = if ($rule.Count) { [string]$rule[0].visibility } else { 'internal_shareable' }
        $projects = @([regex]::Matches("$relative $content", '(?i)Q\d{2,}[A-Z0-9-]*') | ForEach-Object {$_.Value.ToUpperInvariant()} | Select-Object -Unique)
        $category = Get-PdaKnowledgeCategory $relative $content
        $documents += [pscustomobject]@{
            id = Get-PdaDocumentId $relative; title = $title; path = $relative
            folder = Split-Path $relative -Parent; category = $category
            category_label = (Get-PdaPermissionCatalog).categories.$category
            projects = $projects; visibility = $visibility
            visibility_label = if($visibility -eq 'private'){'仅本人'}else{'内部公开'}
            updated_at = $file.LastWriteTimeUtc.ToString('o'); content = $content
        }
    }
    return $documents
}

function Get-PdaPermissionCatalog {
    return [pscustomobject]@{
        roles = [pscustomobject]@{ colleague='普通同事'; project_member='项目成员'; manager='管理人员'; custom='自定义' }
        categories = [pscustomobject]@{ general='通用资料'; project='项目资料'; schedule='项目排期'; technical='技术资料'; sensitive='敏感资料' }
    }
}

function Get-PdaChannelCatalog {
    $common = [pscustomobject]@{receive_realtime=$true;fetch_history=$false;reply_to_message=$true;send_as_user=$false;send_as_bot=$true;supports_ai_label=$false;group_mentions=$true}
    return @(
        [pscustomobject]@{channel_type='dingtalk';display_name='钉钉';sending_identity='bot';capabilities=[pscustomobject]@{receive_realtime=$true;fetch_history=$true;reply_to_message=$true;send_as_user=$true;send_as_bot=$true;supports_ai_label=$true;group_mentions=$true}},
        [pscustomobject]@{channel_type='wecom';display_name='企业微信';sending_identity='app';capabilities=$common},
        [pscustomobject]@{channel_type='feishu';display_name='飞书';sending_identity='bot';capabilities=$common}
    )
}

function ConvertTo-PdaWorkItem {
    param($Item, [string]$Kind, [string]$DataRoot)
    $id = [string]$Item.id
    $due = if($null -ne $Item.PSObject.Properties['due']){[string]$Item.due}else{''}
    $status = if($null -ne $Item.PSObject.Properties['status']){[string]$Item.status}else{'pending'}
    $priority = if($null -ne $Item.PSObject.Properties['priority']){[string]$Item.priority}else{'P2'}
    $metadata = if($null -ne $Item.PSObject.Properties['metadata']){$Item.metadata}else{[pscustomobject]@{}}
    if ($Kind -eq 'followup') {
        $method = if($null -ne $Item.PSObject.Properties['method']){[string]$Item.method}else{'dingtalk_approval'}
        if ($method -notin @('dingtalk_auto','dingtalk_approval','remind_me')) { $method = 'dingtalk_approval' }
        $repeat = if($null -ne $Item.PSObject.Properties['repeat_minutes']){[int]$Item.repeat_minutes}else{0}
        $rule = if($null -ne $Item.PSObject.Properties['rule']){[string]$Item.rule}else{''}
        $metadata = [pscustomobject]@{followup_method=$method;repeat_minutes=$repeat;reminder_text='';custom_rules=$rule}
    }
    return [pscustomobject]@{
        id=$id;code=$id.Substring(0,[Math]::Min(6,$id.Length)).ToUpperInvariant();kind=$Kind
        title=[string]$Item.title;description='';status=$status;priority=$priority;due_at=$due;next_action_at=$due
        owner_name=if($Kind -eq 'followup'){[string]$Item.target}else{''}
        target_answer=if($null -ne $Item.PSObject.Properties['target_answer']){[string]$Item.target_answer}else{[string]$Item.title}
        approval_state=if($null -ne $Item.PSObject.Properties['approval_state']){[string]$Item.approval_state}else{'pending'}
        metadata=$metadata;created_at=[string]$Item.createdAt;updated_at=if($null -ne $Item.PSObject.Properties['updatedAt']){[string]$Item.updatedAt}else{[string]$Item.createdAt}
        chat_count=0;document_path=if($Kind -eq 'followup'){Write-PdaFollowupDocument $Item $DataRoot}else{''}
        nodes=if($null -ne $Item.PSObject.Properties['nodes']){@($Item.nodes)}else{@()}
    }
}

function Get-PdaConsoleSnapshot {
    param([string]$DataRoot)
    $store = Initialize-PdaConsoleSchema (Read-PdaStore $DataRoot) $DataRoot
    $tasks = @($store.tasks | ForEach-Object { ConvertTo-PdaWorkItem $_ 'daily' $DataRoot })
    $followups = @($store.followups | ForEach-Object { ConvertTo-PdaWorkItem $_ 'followup' $DataRoot })
    $projects = @($store.projects | ForEach-Object { ConvertTo-PdaWorkItem $_ 'project' $DataRoot })
    $emails = @($store.emails | ForEach-Object { ConvertTo-PdaWorkItem $_ 'email' $DataRoot })
    $documents = @(Get-PdaKnowledgeDocuments $store $DataRoot)
    $catalog = Get-PdaPermissionCatalog
    foreach ($item in @($store.whitelist)) {
        Set-PdaProperty $item 'permission_summary' ("{0}；{1}" -f $catalog.roles.([string]$item.permission_role), $(if($item.allow_private_knowledge){'可读已授权私有资料'}else{'仅内部公开资料'}))
    }
    $active = @($tasks + $followups + $projects + $emails | Where-Object status -notin @('completed','cancelled','已完成','已关闭'))
    return [pscustomobject]@{
        generated_at=[DateTime]::UtcNow.ToString('o');health=[pscustomobject]@{daemon=$true}
        counts=[pscustomobject]@{tasks=@($tasks | Where-Object status -notin @('completed','cancelled','已完成')).Count;followups=@($followups | Where-Object status -notin @('completed','cancelled','已关闭')).Count;projects=@($projects | Where-Object status -notin @('completed','cancelled')).Count;emails=@($emails | Where-Object status -notin @('completed','cancelled')).Count;overdue=@($active | Where-Object status -eq 'overdue').Count}
        tasks=$tasks;followups=$followups;projects=$projects;emails=$emails;whitelist=@($store.whitelist);channels=@($store.channels)
        channel_catalog=@(Get-PdaChannelCatalog);email_status='待授权：请配置邮件适配器'
        settings=[pscustomobject]@{dingtalk_ai_tag=[bool]$store.config.dingtalkAiTag}
        profile=[pscustomobject]@{owner_name=[string]$store.config.ownerName;workspace_name=[string]$store.config.workspaceName;timezone=[string]$store.config.timeZone;daily_digest_time=[string]$store.config.digestTime;setup_completed=[bool]$store.config.setupCompleted}
        permission_catalog=$catalog
        knowledge_permissions=[pscustomobject]@{total=$documents.Count;counts=[pscustomobject]@{internal_shareable=@($documents | Where-Object visibility -eq 'internal_shareable').Count;private=@($documents | Where-Object visibility -eq 'private').Count};documents=@($documents | Select-Object -Property * -ExcludeProperty content);events=@($store.permissionEvents);projects=@($documents | ForEach-Object {$_.projects} | Select-Object -Unique);folders=@($documents | ForEach-Object {$_.folder} | Select-Object -Unique);categories=$catalog.categories}
    }
}

function Save-PdaProtectedSecret {
    param($Store, [string]$ChannelType, [string]$Secret)
    if (-not $Secret) { return '' }
    $root = Join-Path $env:LOCALAPPDATA 'PersonalDigitalAssistantProtected'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $path = Join-Path $root ("{0}-{1}.secret" -f $Store.instanceId,$ChannelType)
    ConvertTo-SecureString $Secret -AsPlainText -Force | ConvertFrom-SecureString | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Invoke-PdaConsoleAction {
    param($Body, [string]$DataRoot)
    $store = Initialize-PdaConsoleSchema (Read-PdaStore $DataRoot) $DataRoot
    $action = [string]$Body.action
    $now = [DateTime]::UtcNow.ToString('o')
    switch ($action) {
        'instance-initialize' {
            if (-not $Body.owner_name) { throw '请填写助理服务对象的姓名。' }
            $store.config.ownerName=[string]$Body.owner_name;$store.config.workspaceName=[string]$Body.workspace_name;$store.config.timeZone=[string]$Body.timezone;$store.config.digestTime=[string]$Body.daily_digest_time;$store.config.setupCompleted=$true
            Add-PdaAudit $store 'profile_updated' '更新助理基础信息'; Write-PdaStore $store $DataRoot; return @{ok=$true;message='基础信息已保存。'}
        }
        'settings-update' {
            if($null -ne $Body.PSObject.Properties['dingtalk_ai_tag']){$store.config.dingtalkAiTag=[bool]$Body.dingtalk_ai_tag;$store.config.aiLabelEnabled=[bool]$Body.dingtalk_ai_tag}
            Add-PdaAudit $store 'settings_updated' '更新系统设置'; Write-PdaStore $store $DataRoot; return @{ok=$true;message='系统设置已保存。'}
        }
        'whitelist-create' {
            if(-not $Body.name){throw '请填写联系人姓名。'}
            $item=[pscustomobject]@{id=[guid]::NewGuid().ToString('N');name=[string]$Body.name;channel='dingtalk';identity=[string]$Body.user_id;user_id=[string]$Body.user_id;open_id=[string]$Body.open_id;notes=[string]$Body.notes;enabled=[bool]$Body.enabled;human_reply_guard_enabled=$true;permission_role=[string]$Body.permission_role;allow_private_knowledge=[bool]$Body.allow_private_knowledge;allowed_categories=@($Body.allowed_categories);denied_categories=@($Body.denied_categories);allowed_projects=@($Body.allowed_projects);custom_reply_rules=[string]$Body.custom_reply_rules;permission_events=@();knowledge_access_events=@();createdAt=$now}
            $store.whitelist=@($store.whitelist)+$item;Add-PdaAudit $store 'whitelist_added' "添加白名单：$($item.name)";Write-PdaStore $store $DataRoot;return @{ok=$true;message="已加入白名单：$($item.name)"}
        }
        'whitelist-update' {
            $item=@($store.whitelist|Where-Object id -eq ([string]$Body.id)|Select-Object -First 1);if(-not $item){throw '白名单联系人不存在。'};$item=$item[0]
            foreach($name in @('name','user_id','open_id','notes','enabled','human_reply_guard_enabled','permission_role','allow_private_knowledge','allowed_categories','denied_categories','allowed_projects','custom_reply_rules')){if($null -ne $Body.PSObject.Properties[$name]){Set-PdaProperty $item $name $Body.$name}}
            $event=[pscustomobject]@{event_type='permission_updated';created_at=$now};$item.permission_events=@($event)+@($item.permission_events)|Select-Object -First 20
            Add-PdaAudit $store 'whitelist_updated' "更新白名单：$($item.name)";Write-PdaStore $store $DataRoot;return @{ok=$true;message="已更新白名单：$($item.name)"}
        }
        'whitelist-delete' { $item=@($store.whitelist|Where-Object id -eq ([string]$Body.id)|Select-Object -First 1);if(-not $item){throw '白名单联系人不存在。'};$store.whitelist=@($store.whitelist|Where-Object id -ne ([string]$Body.id));Add-PdaAudit $store 'whitelist_removed' "移除白名单：$($item[0].name)";Write-PdaStore $store $DataRoot;return @{ok=$true;message="已移出白名单：$($item[0].name)"} }
        'whitelist-permission-simulate' {
            $item=@($store.whitelist|Where-Object id -eq ([string]$Body.id)|Select-Object -First 1);if(-not $item){throw '白名单联系人不存在。'};$item=$item[0]
            if(-not $item.enabled){return @{ok=$true;message='模拟结果：该联系人已停用，实际消息只记录。'}}
            $results=@(Search-PdaKnowledge -Query ([string]$Body.query) -DataRoot $DataRoot -Store $store | Where-Object {$item.allow_private_knowledge -or $_.visibility -ne 'private'} | Where-Object {$item.denied_categories -notcontains $_.category} | Select-Object -First 5)
            $event=[pscustomobject]@{category='simulation';source=[string]$Body.query;created_at=$now};$item.knowledge_access_events=@($event)+@($item.knowledge_access_events)|Select-Object -First 20;Write-PdaStore $store $DataRoot
            if(-not $results){return @{ok=$true;message='模拟结果：没有找到权限范围内的可靠资料，实际消息将升级给主人。'}}
            return @{ok=$true;message=("模拟结果：允许使用以下资料`n" + (($results|ForEach-Object{"- $($_.title)"}) -join "`n"))}
        }
        'task-create' {
            $text=[string]$Body.text;$priority=if($text -match '\bP[0-3]\b'){$Matches[0]}else{'P2'};$title=($text -replace '\bP[0-3]\b','').Trim();if(-not $title){throw '请填写待办内容。'}
            $item=[pscustomobject]@{id=[guid]::NewGuid().ToString('N');title=$title;due='';status='pending';priority=$priority;createdAt=$now;updatedAt=$now};$store.tasks=@($store.tasks)+$item;Add-PdaAudit $store 'task_added' "新增待办：$title";Write-PdaStore $store $DataRoot;return @{ok=$true;message="已新增待办：$title"}
        }
        'task-complete' { $item=@($store.tasks|Where-Object id -eq ([string]$Body.text)|Select-Object -First 1);if(-not $item){throw '待办不存在。'};$item[0].status='completed';Set-PdaProperty $item[0] 'updatedAt' $now;Write-PdaStore $store $DataRoot;return @{ok=$true;message='待办已完成。'} }
        'task-delay' { $id=([string]$Body.text -split '\s+')[-1];$value=([string]$Body.text).Substring(0,([string]$Body.text).LastIndexOf($id)).Trim();$item=@($store.tasks|Where-Object id -eq $id|Select-Object -First 1);if(-not $item){throw '待办不存在。'};$item[0].due=$value;Set-PdaProperty $item[0] 'updatedAt' $now;Write-PdaStore $store $DataRoot;return @{ok=$true;message="待办已延期到：$value"} }
        'task-delete' { $store.tasks=@($store.tasks|Where-Object id -ne ([string]$Body.id));Add-PdaAudit $store 'task_removed' "删除待办：$($Body.id)";Write-PdaStore $store $DataRoot;return @{ok=$true;message='待办已删除。'} }
        'followup-create-structured' {
            if(-not $Body.title -or -not $Body.owner_name){throw '请填写跟进事项和对象。'};$unit=@{minutes=1;hours=60;days=1440;weeks=10080}[[string]$Body.repeat_unit];if(-not $unit){$unit=1440}
            $item=[pscustomobject]@{id=[guid]::NewGuid().ToString('N');title=[string]$Body.title;target=[string]$Body.owner_name;method=[string]$Body.followup_method;cycle=[string]$Body.schedule;rule=[string]$Body.custom_rules;target_answer=[string]$Body.target_answer;repeat_minutes=([int]$Body.repeat_value*$unit);due=[string]$Body.schedule;status='pending';priority='P2';createdAt=$now;updatedAt=$now};$store.followups=@($store.followups)+$item;Write-PdaFollowupDocument $item $DataRoot|Out-Null;Add-PdaAudit $store 'followup_added' "新增跟进：$($item.title)";Write-PdaStore $store $DataRoot;return @{ok=$true;message="已新增跟进：$($item.title)"}
        }
        'followup-update-structured' {
            $item=@($store.followups|Where-Object id -eq ([string]$Body.id)|Select-Object -First 1);if(-not $item){throw '跟进任务不存在。'};$item=$item[0];$unit=@{minutes=1;hours=60;days=1440;weeks=10080}[[string]$Body.repeat_unit];if(-not $unit){$unit=1440}
            $item.title=[string]$Body.title;$item.method=[string]$Body.followup_method;$item.rule=[string]$Body.custom_rules;$item.target_answer=[string]$Body.target_answer;$item.repeat_minutes=[int]$Body.repeat_value*$unit;if($Body.schedule){$item.due=[string]$Body.schedule};$item.updatedAt=$now;Write-PdaFollowupDocument $item $DataRoot|Out-Null;Write-PdaStore $store $DataRoot;return @{ok=$true;message="已更新跟进：$($item.title)"}
        }
        'followup-close' { $item=@($store.followups|Where-Object id -eq ([string]$Body.text)|Select-Object -First 1);if(-not $item){throw '跟进任务不存在。'};$item[0].status='completed';$item[0].updatedAt=$now;Write-PdaStore $store $DataRoot;return @{ok=$true;message='跟进已结束。'} }
        'followup-delete' { $store.followups=@($store.followups|Where-Object id -ne ([string]$Body.id));Add-PdaAudit $store 'followup_removed' "删除跟进：$($Body.id)";Write-PdaStore $store $DataRoot;return @{ok=$true;message='跟进已删除，过程文档已保留。'} }
        'project-create' {
            $lines=@(([string]$Body.text -split "`r?`n")|ForEach-Object{$_.Trim()}|Where-Object{$_});if(-not $lines){throw '请粘贴项目计划。'};$nodes=@($lines|Select-Object -Skip 1|ForEach-Object{[pscustomobject]@{title=$_;owner_name='';due_at='';status='pending'}})
            $item=[pscustomobject]@{id=[guid]::NewGuid().ToString('N');title=$lines[0];due='';status='pending';priority='P2';approval_state='pending';nodes=$nodes;createdAt=$now;updatedAt=$now};$store.projects=@($store.projects)+$item;Add-PdaAudit $store 'project_added' "新增项目：$($item.title)";Write-PdaStore $store $DataRoot;return @{ok=$true;message="已导入项目：$($item.title)"}
        }
        'project-approve' { $item=@($store.projects|Where-Object id -eq ([string]$Body.text)|Select-Object -First 1);if(-not $item){throw '项目不存在。'};$item[0].approval_state='approved';Write-PdaStore $store $DataRoot;return @{ok=$true;message='项目已批准。'} }
        'knowledge-permission-bulk' {
            $docs=@(Get-PdaKnowledgeDocuments $store $DataRoot);$matched=switch([string]$Body.scope_type){'document'{@($docs|Where-Object id -eq ([string]$Body.scope_value))}'folder'{@($docs|Where-Object folder -eq ([string]$Body.scope_value))}'project'{@($docs|Where-Object projects -contains ([string]$Body.scope_value))}'category'{@($docs|Where-Object category -eq ([string]$Body.scope_value))}default{$docs}}
            foreach($doc in $matched){$store.knowledgePermissions=@($store.knowledgePermissions|Where-Object path -ne $doc.path)+[pscustomobject]@{path=$doc.path;visibility=[string]$Body.visibility;updated_at=$now}}
            $store.permissionEvents=@([pscustomobject]@{scope_type=[string]$Body.scope_type;scope_value=[string]$Body.scope_value;target_visibility=[string]$Body.visibility;affected_count=$matched.Count;created_at=$now})+@($store.permissionEvents)|Select-Object -First 100;Add-PdaAudit $store 'knowledge_permission_updated' "修改知识权限：$($matched.Count)份";Write-PdaStore $store $DataRoot;return @{ok=$true;message="已更新 $($matched.Count) 份资料，索引将在下次搜索时自动重建。"}
        }
        'channel-bind' {
            $type=[string]$Body.channel_type;$meta=@(Get-PdaChannelCatalog|Where-Object channel_type -eq $type|Select-Object -First 1);if(-not $meta){throw '不支持该沟通渠道。'};$secretRef=Save-PdaProtectedSecret $store $type ([string]$Body.secret)
            $store.channels=@($store.channels|Where-Object channel_type -ne $type)+[pscustomobject]@{id=[guid]::NewGuid().ToString('N');channel_type=$type;display_name=$meta[0].display_name;account_id=[string]$Body.account_id;secret_ref=$secretRef;status='configured';sending_identity=$meta[0].sending_identity;capabilities=$meta[0].capabilities;last_error='适配器尚未完成在线验证'};Add-PdaAudit $store 'channel_configured' "配置渠道：$($meta[0].display_name)";Write-PdaStore $store $DataRoot;return @{ok=$true;message="已安全保存$($meta[0].display_name)配置；启动对应适配器后将自动验证连接。"}
        }
        'channel-test' { return @{ok=$true;message='配置已保存；需要对应平台适配器在线后才能完成连接测试。'} }
        'channel-unbind' { $item=@($store.channels|Where-Object id -eq ([string]$Body.id)|Select-Object -First 1);if(-not $item){throw '渠道不存在。'};if($item[0].secret_ref -and (Test-Path -LiteralPath $item[0].secret_ref)){Remove-Item -LiteralPath $item[0].secret_ref -Force};$store.channels=@($store.channels|Where-Object id -ne ([string]$Body.id));Add-PdaAudit $store 'channel_unbound' "解绑渠道：$($item[0].display_name)";Write-PdaStore $store $DataRoot;return @{ok=$true;message="已解绑：$($item[0].display_name)"} }
        default { throw "暂不支持的操作：$action" }
    }
}

function Search-PdaKnowledge {
    param([string]$Query, [string]$DataRoot, $Store)
    if (-not $Store) { $Store = Initialize-PdaConsoleSchema (Read-PdaStore $DataRoot) $DataRoot }
    $terms=@($Query -split '[\s，。！？、：；]+'|Where-Object{$_.Length -ge 2})
    $results=@()
    foreach($doc in Get-PdaKnowledgeDocuments $Store $DataRoot){$score=0;foreach($term in $terms){$score+=([regex]::Matches($doc.content,[regex]::Escape($term),'IgnoreCase')).Count*10;if($doc.title -match [regex]::Escape($term)){$score+=20}};if($score -gt 0 -or -not $terms){$snippet=($doc.content -replace '\s+',' ').Trim();if($snippet.Length -gt 260){$snippet=$snippet.Substring(0,260)+'…'};$results+=[pscustomobject]@{title=$doc.title;heading='';snippet=$snippet;provenance=$doc.path;source=$doc.path;updated_at=$doc.updated_at;visibility=$doc.visibility;category=$doc.category;score=$score}}}
    return @($results|Sort-Object score -Descending)
}
