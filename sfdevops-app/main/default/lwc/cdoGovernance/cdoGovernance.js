import { LightningElement, api, wire } from 'lwc';
import LightningConfirm from 'lightning/confirm';
import getContext from '@salesforce/apex/GovernanceController.getContext';
import getAuditEvents from '@salesforce/apex/GovernanceController.getAuditEvents';
import getEventTypes from '@salesforce/apex/GovernanceController.getEventTypes';
import getPendingPromotions from '@salesforce/apex/GovernanceController.getPendingPromotions';
import recordApproval from '@salesforce/apex/GovernanceController.recordApproval';
import rollback from '@salesforce/apex/GovernanceOpsController.rollback';
import redeployFeature from '@salesforce/apex/GovernanceOpsController.redeployFeature';
import recreateFeature from '@salesforce/apex/GovernanceOpsController.recreateFeature';
import syncEnvBranches from '@salesforce/apex/GovernanceOpsController.syncEnvBranches';
import runConflictCheck from '@salesforce/apex/GovernanceOpsController.runConflictCheck';
import getHealth from '@salesforce/apex/IntegrationController.getHealth';
import testGitHubConnection from '@salesforce/apex/IntegrationController.testGitHubConnection';
import {
    errorMessage,
    formatDateTime,
    formatRelative,
    labelOf,
    recordUrl,
    refreshAll,
    showError,
    showToast
} from 'c/cdoUtils';

const AUDIT_COLUMNS = [
    { label: 'Event', fieldName: 'url', type: 'url', typeAttributes: { label: { fieldName: 'Name' }, target: '_self' }, initialWidth: 130 },
    {
        label: 'When',
        fieldName: 'CreatedDate',
        type: 'date',
        initialWidth: 170,
        typeAttributes: { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' }
    },
    { label: 'Type', fieldName: 'Event_Type__c', initialWidth: 120 },
    { label: 'Summary', fieldName: 'Summary__c', wrapText: true },
    { label: 'Actor', fieldName: 'Actor__c', initialWidth: 140 },
    { label: 'Source', fieldName: 'Source__c', initialWidth: 90 },
    { label: 'Work item', fieldName: 'workItemUrl', type: 'url', typeAttributes: { label: { fieldName: 'workItemName' }, target: '_self' }, initialWidth: 110 },
    { label: 'Promotion', fieldName: 'promotionUrl', type: 'url', typeAttributes: { label: { fieldName: 'promotionName' }, target: '_self' }, initialWidth: 120 },
    { label: 'Run', fieldName: 'Run_URL__c', type: 'url', typeAttributes: { label: 'Run', target: '_blank' }, initialWidth: 70 },
    { type: 'action', typeAttributes: { rowActions: [{ label: 'View details', name: 'details' }] } }
];

const PENDING_COLUMNS = [
    { label: 'Promotion', fieldName: 'url', type: 'url', typeAttributes: { label: { fieldName: 'name' }, target: '_self' }, initialWidth: 120 },
    { label: 'Route', fieldName: 'route', initialWidth: 170 },
    { label: 'Work items', fieldName: 'workItems', wrapText: true },
    { label: 'Requested by', fieldName: 'requestedByName', initialWidth: 140 },
    { label: 'Requested', fieldName: 'requestedLabel', initialWidth: 120 },
    { label: 'Note', fieldName: 'note', wrapText: true },
    {
        type: 'button',
        initialWidth: 110,
        typeAttributes: { label: 'Approve', name: 'approve', variant: 'brand', disabled: { fieldName: 'approveDisabled' }, title: 'Approve and deploy' }
    },
    {
        type: 'button',
        initialWidth: 100,
        typeAttributes: { label: 'Reject', name: 'reject', variant: 'destructive-text', disabled: { fieldName: 'approveDisabled' }, title: 'Reject and cancel' }
    }
];

const LIMIT_OPTIONS = ['50', '100', '250', '500', '1000'].map((v) => ({ label: `${v} events`, value: v }));

const WORK_ITEM_DISPLAY = { additionalFields: ['Subject__c'] };
const WORK_ITEM_MATCHING = { primaryField: { fieldPath: 'Name' }, additionalFields: [{ fieldPath: 'Subject__c' }] };

/**
 * Governance: the audit log with filters, pending (Draft) promotions to approve or reject,
 * governance operations for users with CDO_Governance_Ops, and GitHub integration health.
 */
export default class CdoGovernance extends LightningElement {
    @api recordId;
    @api objectApiName;

    context;
    eventType = '';
    workItemFilter = null;
    limitSize = '100';
    eventTypes = [];
    events = [];
    auditError;
    selectedEvent;
    pending = [];
    pendingError;
    decision; // { promotion, decision, comments }
    working = false;

    // ops form state
    rollbackEnv;
    rollbackSha = '';
    rollbackReason = '';
    redeployWorkItemId;
    redeployEnv;
    recreateWorkItemId;
    syncEnv = '';

    health;
    healthError;
    healthLoading = false;

    auditResult;
    pendingResult;
    typesResult;

    auditColumns = AUDIT_COLUMNS;
    pendingColumns = PENDING_COLUMNS;
    limitOptions = LIMIT_OPTIONS;
    shaPattern = '[0-9a-fA-F]{7,40}';
    workItemDisplayInfo = WORK_ITEM_DISPLAY;
    workItemMatchingInfo = WORK_ITEM_MATCHING;

    connectedCallback() {
        if (this.objectApiName === 'CDO_Work_Item__c' && this.recordId) {
            this.workItemFilter = this.recordId;
        }
    }

    @wire(getContext)
    wiredContext({ data }) {
        if (data) {
            this.context = data;
        }
    }

    @wire(getEventTypes)
    wiredTypes(result) {
        this.typesResult = result;
        if (result.data) {
            this.eventTypes = result.data;
        }
    }

    @wire(getAuditEvents, { eventType: '$eventType', workItemId: '$workItemFilter', limitSize: '$limitNumber' })
    wiredAudit(result) {
        this.auditResult = result;
        if (result.data) {
            this.events = result.data;
            this.auditError = undefined;
        } else if (result.error) {
            this.auditError = errorMessage(result.error);
        }
    }

    @wire(getPendingPromotions)
    wiredPending(result) {
        this.pendingResult = result;
        if (result.data) {
            this.pending = result.data;
            this.pendingError = undefined;
        } else if (result.error) {
            this.pendingError = errorMessage(result.error);
        }
    }

    // -----------------------------------------------------------------------------------------
    // View state
    // -----------------------------------------------------------------------------------------

    get limitNumber() {
        return Number(this.limitSize);
    }

    get eventTypeOptions() {
        return [{ label: 'All event types', value: '' }, ...this.eventTypes.map((t) => ({ label: t, value: t }))];
    }

    get auditRows() {
        return this.events.map((e) => ({
            ...e,
            url: recordUrl(e.Id, 'CDO_Audit_Event__c'),
            workItemName: e.Work_Item__r ? e.Work_Item__r.Name : '',
            workItemUrl: e.Work_Item__c ? recordUrl(e.Work_Item__c, 'CDO_Work_Item__c') : null,
            promotionName: e.Promotion__r ? e.Promotion__r.Name : '',
            promotionUrl: e.Promotion__c ? recordUrl(e.Promotion__c, 'CDO_Promotion__c') : null
        }));
    }

    get hasEvents() {
        return this.events.length > 0;
    }

    get auditCountLabel() {
        const n = this.events.length;
        return `${n} event${n === 1 ? '' : 's'}${n >= this.limitNumber ? ' (limit reached; narrow the filters to see older events)' : ''}`;
    }

    get selectedEventWhen() {
        return this.selectedEvent ? formatDateTime(this.selectedEvent.Occurred_On__c || this.selectedEvent.CreatedDate) : '';
    }

    get pendingRows() {
        return this.pending.map((p) => ({
            ...p,
            url: recordUrl(p.id, 'CDO_Promotion__c'),
            route: `${p.sourceStageName || 'Backlog'} → ${p.targetStageName || ''}`,
            requestedLabel: formatRelative(p.createdDate),
            note: p.approvalBlockedReason || p.coverageHold || (p.gateType ? `Gate: ${labelOf(p.gateType)}` : ''),
            approveDisabled: !p.canApprove
        }));
    }

    get hasPending() {
        return this.pending.length > 0;
    }

    get pendingTabLabel() {
        return this.pending.length ? `Pending promotions (${this.pending.length})` : 'Pending promotions';
    }

    get canRunOps() {
        return this.context && this.context.canRunOps;
    }

    get envOptions() {
        return this.context ? this.context.pipelineKeys : [];
    }

    get syncEnvOptions() {
        return [{ label: 'All environment branches', value: '' }, ...this.envOptions];
    }

    get isDeciding() {
        return !!this.decision;
    }

    get decisionTitle() {
        if (!this.decision) {
            return '';
        }
        return `${this.decision.decision === 'Approved' ? 'Approve' : 'Reject'} ${this.decision.promotion.name}`;
    }

    get decisionIsReject() {
        return this.decision && this.decision.decision === 'Rejected';
    }

    get decisionButtonLabel() {
        return this.decisionIsReject ? 'Reject and cancel' : 'Approve and deploy';
    }

    get decisionButtonClass() {
        return this.decisionIsReject ? 'slds-button slds-button_destructive' : 'slds-button slds-button_brand';
    }

    get decisionHelp() {
        if (!this.decision) {
            return '';
        }
        const p = this.decision.promotion;
        return this.decisionIsReject
            ? `${p.name} will be cancelled. Its work items stay where they are.`
            : `${p.name} (${p.workItems}) will be queued for ${p.targetStageName}.${p.coverageHold ? ' It will be held: ' + p.coverageHold : ''}`;
    }

    get rollbackDisabled() {
        return this.working || !this.rollbackEnv || !this.rollbackSha.trim() || !this.rollbackReason.trim();
    }

    get redeployDisabled() {
        return this.working || !this.redeployWorkItemId || !this.redeployEnv;
    }

    get recreateDisabled() {
        return this.working || !this.recreateWorkItemId;
    }

    get healthItems() {
        if (!this.health) {
            return [];
        }
        const h = this.health;
        return [
            {
                key: 'settings',
                label: 'SF DevOps Settings',
                ok: h.settingsComplete,
                detail: h.settingsComplete
                    ? `GitHub owner and repo are set. Workflows run from ref ${h.workflowRef}.`
                    : `Missing: ${h.missingSettings.join(', ')}.`
            },
            {
                key: 'dispatch',
                label: 'Dispatch',
                ok: h.dispatchEnabled,
                detail: h.dispatchEnabled ? 'Workflows are dispatched to GitHub.' : 'Dispatch is turned off in SF DevOps Settings.'
            },
            {
                key: 'credential',
                label: `Named Credential ${h.namedCredential || ''}`,
                ok: h.namedCredentialReachable,
                detail: h.namedCredentialMessage
            },
            {
                key: 'callback',
                label: 'Last callback from GitHub',
                ok: !!h.lastCallbackOn,
                detail: h.lastCallbackOn
                    ? `${formatRelative(h.lastCallbackOn)}: ${h.lastCallbackSummary || ''}`
                    : 'No callback received yet. Check the HUB_* repository secrets.'
            }
        ].map((item) => ({
            ...item,
            iconName: item.ok ? 'utility:success' : 'utility:warning',
            iconVariant: item.ok ? 'success' : 'warning',
            iconText: item.ok ? 'OK' : 'Needs attention'
        }));
    }

    // -----------------------------------------------------------------------------------------
    // Audit handlers
    // -----------------------------------------------------------------------------------------

    handleEventTypeChange(event) {
        this.eventType = event.detail.value;
    }

    handleWorkItemFilterChange(event) {
        this.workItemFilter = event.detail.recordId || null;
    }

    handleLimitChange(event) {
        this.limitSize = event.detail.value;
    }

    handleAuditRowAction(event) {
        if (event.detail.action.name === 'details') {
            this.selectedEvent = event.detail.row;
        }
    }

    handleCloseDetails() {
        this.selectedEvent = undefined;
    }

    handleRefresh() {
        refreshAll(this.auditResult, this.pendingResult, this.typesResult).catch((e) => showError(this, 'Could not refresh', e));
    }

    // -----------------------------------------------------------------------------------------
    // Approvals
    // -----------------------------------------------------------------------------------------

    handlePendingRowAction(event) {
        const { action, row } = event.detail;
        const promotion = this.pending.find((p) => p.id === row.id);
        if (!promotion) {
            return;
        }
        this.decision = { promotion, decision: action.name === 'approve' ? 'Approved' : 'Rejected', comments: '' };
    }

    handleCommentsChange(event) {
        this.decision = { ...this.decision, comments: event.detail.value };
    }

    handleCloseDecision() {
        this.decision = undefined;
    }

    handleModalKeydown(event) {
        if (event.key === 'Escape') {
            this.handleCloseDecision();
        }
    }

    async handleSubmitDecision() {
        if (this.decisionIsReject) {
            const textarea = this.template.querySelector('.decision-comments');
            if (textarea && !textarea.reportValidity()) {
                return;
            }
        }
        this.working = true;
        try {
            const result = await recordApproval({
                promotionId: this.decision.promotion.id,
                decision: this.decision.decision,
                comments: this.decision.comments
            });
            showToast(this, result.decision === 'Approved' ? 'Approved' : 'Rejected', result.message, result.dispatched === false && result.decision === 'Approved' ? 'warning' : 'success');
            this.decision = undefined;
            await refreshAll(this.pendingResult, this.auditResult, this.typesResult);
        } catch (e) {
            showError(this, 'Could not record the decision', e);
        } finally {
            this.working = false;
        }
    }

    // -----------------------------------------------------------------------------------------
    // Operations
    // -----------------------------------------------------------------------------------------

    handleOpsField(event) {
        const field = event.target.dataset.field;
        this[field] = event.detail.value !== undefined ? event.detail.value : event.detail.recordId;
    }

    handleOpsRecord(event) {
        const field = event.target.dataset.field;
        this[field] = event.detail.recordId || undefined;
    }

    async runOp(label, confirmMessage, call) {
        const confirmed = await LightningConfirm.open({ message: confirmMessage, label, theme: 'warning' });
        if (!confirmed) {
            return false;
        }
        this.working = true;
        try {
            const message = await call();
            showToast(this, `${label} started`, message, 'success');
            await refreshAll(this.auditResult, this.typesResult);
            return true;
        } catch (e) {
            showError(this, `${label} failed`, e);
            return false;
        } finally {
            this.working = false;
        }
    }

    async handleRollback() {
        const done = await this.runOp(
            'Rollback',
            `Redeploy ${this.rollbackEnv} at commit ${this.rollbackSha.trim()}? This replaces what is deployed there now.`,
            () => rollback({ targetEnv: this.rollbackEnv, sha: this.rollbackSha.trim(), reason: this.rollbackReason.trim() })
        );
        if (done) {
            this.rollbackSha = '';
            this.rollbackReason = '';
        }
    }

    handleRedeploy() {
        this.runOp(
            'Redeploy feature',
            `Redeploy the work item's feature branch to ${this.redeployEnv}?`,
            () => redeployFeature({ workItemId: this.redeployWorkItemId, targetEnv: this.redeployEnv })
        );
    }

    handleRecreate() {
        this.runOp(
            'Recreate feature',
            "Recreate the work item's feature branch from the baseline with its tracked components? The existing branch is replaced.",
            () => recreateFeature({ workItemId: this.recreateWorkItemId })
        );
    }

    handleSync() {
        const scope = this.syncEnv ? `the ${this.syncEnv} branch` : 'all environment branches';
        this.runOp('Sync', `Re-align ${scope} with what is deployed?`, () => syncEnvBranches({ targetEnv: this.syncEnv }));
    }

    handleConflictCheck() {
        this.runOp(
            'Conflict check',
            'Check all in-flight work items for overlapping components? Overlaps are flagged on the components.',
            () => runConflictCheck()
        );
    }

    // -----------------------------------------------------------------------------------------
    // Integration health
    // -----------------------------------------------------------------------------------------

    handleHealthTab() {
        if (!this.health && !this.healthLoading) {
            this.loadHealth();
        }
    }

    async loadHealth() {
        this.healthLoading = true;
        try {
            this.health = await getHealth();
            this.healthError = undefined;
        } catch (e) {
            this.healthError = errorMessage(e);
        } finally {
            this.healthLoading = false;
        }
    }

    async handleTestConnection() {
        this.healthLoading = true;
        try {
            const result = await testGitHubConnection();
            showToast(this, result.ok ? 'Connected to GitHub' : 'GitHub connection failed', result.message, result.ok ? 'success' : 'error');
            await this.loadHealth();
        } catch (e) {
            showError(this, 'Could not test the connection', e);
        } finally {
            this.healthLoading = false;
        }
    }
}
