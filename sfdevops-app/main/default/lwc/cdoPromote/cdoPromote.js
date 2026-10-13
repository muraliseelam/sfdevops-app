import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getStages from '@salesforce/apex/PromotionController.getStages';
import getPromotionCandidates from '@salesforce/apex/PromotionController.getPromotionCandidates';
import getPromotion from '@salesforce/apex/PromotionController.getPromotion';
import createPromotion from '@salesforce/apex/PromotionController.createPromotion';
import deployPromotion from '@salesforce/apex/PromotionController.deployPromotion';
import cancelPromotion from '@salesforce/apex/PromotionController.cancelPromotion';
import {
    errorMessage,
    formatDateTime,
    formatPercent,
    labelOf,
    recordPageRef,
    recordUrl,
    refreshAll,
    showError,
    showToast,
    statusBadgeClass
} from 'c/cdoUtils';

const POLL_MS = 15000;

const CANDIDATE_COLUMNS = [
    { label: 'Work item', fieldName: 'url', type: 'url', typeAttributes: { label: { fieldName: 'name' }, target: '_self' }, initialWidth: 120 },
    { label: 'Subject', fieldName: 'subject', wrapText: true },
    { label: 'Status', fieldName: 'statusLabel', initialWidth: 120 },
    { label: 'Developer', fieldName: 'developerName', initialWidth: 150 },
    { label: 'PR approved', fieldName: 'prApproved', type: 'boolean', initialWidth: 110 },
    { label: 'Coverage', fieldName: 'coverageLabel', initialWidth: 100 },
    { label: 'Release', fieldName: 'releaseName', initialWidth: 130 }
];

const JUNCTION_COLUMNS = [
    { label: 'Work item', fieldName: 'url', type: 'url', typeAttributes: { label: { fieldName: 'workItemName' }, target: '_self' }, initialWidth: 120 },
    { label: 'Subject', fieldName: 'subject', wrapText: true },
    { label: 'In this promotion', fieldName: 'statusLabel', initialWidth: 140 },
    { label: 'Work item status', fieldName: 'workItemStatusLabel', initialWidth: 140 },
    { label: 'Current stage', fieldName: 'currentStageName', initialWidth: 130 }
];

const DEPLOYMENT_COLUMNS = [
    { label: 'Deployment', fieldName: 'url', type: 'url', typeAttributes: { label: { fieldName: 'name' }, target: '_self' }, initialWidth: 120 },
    { label: 'Status', fieldName: 'statusLabel', initialWidth: 110 },
    { label: 'Type', fieldName: 'kindLabel', initialWidth: 110 },
    { label: 'Coverage', fieldName: 'coverageLabel', initialWidth: 100 },
    { label: 'When', fieldName: 'whenLabel' },
    { label: 'Run', fieldName: 'runUrl', type: 'url', typeAttributes: { label: 'Open run', target: '_blank' }, initialWidth: 100 }
];

const TEST_LEVEL_OPTIONS = [
    { label: 'Default (stage setting)', value: '' },
    { label: 'No tests', value: 'NoTestRun' },
    { label: 'Specified tests', value: 'RunSpecifiedTests' },
    { label: 'Local tests', value: 'RunLocalTests' },
    { label: 'All tests in org', value: 'RunAllTestsInOrg' }
];

/**
 * Promotions. On a promotion record page: the promotion's status, the work items it carries
 * (junction rows), its deployments and approvals, with Deploy and Cancel. Anywhere else: pick a
 * target stage, select candidate work items, then Promote (Draft) or Promote & Deploy.
 */
export default class CdoPromote extends NavigationMixin(LightningElement) {
    @api recordId;
    @api objectApiName;
    @api projectId;
    /** Hide the stage picker when the parent already chose the stage (the pipeline modal). */
    @api hideStagePicker = false;

    /** The stage to promote into. */
    @api
    get targetStageId() {
        return this.selectedStageId;
    }
    set targetStageId(value) {
        this.selectedStageId = value;
        this.selectedIds = [];
    }

    selectedStageId;
    selectedIds = [];
    testLevel = '';
    specifiedTests = '';
    checkOnly = false;
    working = false;
    createdPromotionId;

    stageOptionsData = [];
    candidatesResult;
    candidateView;
    candidateError;
    promotionResult;
    promotionView;
    promotionError;
    pollTimer;

    candidateColumns = CANDIDATE_COLUMNS;
    junctionColumns = JUNCTION_COLUMNS;
    deploymentColumns = DEPLOYMENT_COLUMNS;
    testLevelOptions = TEST_LEVEL_OPTIONS;

    // -----------------------------------------------------------------------------------------
    // Data
    // -----------------------------------------------------------------------------------------

    @wire(getStages, { projectId: '$projectKey' })
    wiredStages({ data }) {
        if (data) {
            this.stageOptionsData = data;
        }
    }

    @wire(getPromotionCandidates, { targetStageId: '$candidateStageId' })
    wiredCandidates(result) {
        this.candidatesResult = result;
        if (result.data) {
            this.candidateView = result.data;
            this.candidateError = undefined;
            const eligible = new Set(result.data.candidates.map((c) => c.workItemId));
            this.selectedIds = this.selectedIds.filter((id) => eligible.has(id));
        } else if (result.error) {
            this.candidateError = errorMessage(result.error);
            this.candidateView = undefined;
        }
    }

    @wire(getPromotion, { promotionId: '$promotionId' })
    wiredPromotion(result) {
        this.promotionResult = result;
        if (result.data) {
            this.promotionView = result.data;
            this.promotionError = undefined;
            this.syncPolling();
        } else if (result.error) {
            this.promotionError = errorMessage(result.error);
            this.promotionView = undefined;
            this.stopPolling();
        }
    }

    disconnectedCallback() {
        this.stopPolling();
    }

    // -----------------------------------------------------------------------------------------
    // View state
    // -----------------------------------------------------------------------------------------

    /** Null (not undefined) so the wire runs and the server picks the default project. */
    get projectKey() {
        return this.projectId || null;
    }

    get isDetailMode() {
        return this.objectApiName === 'CDO_Promotion__c' && !!this.recordId;
    }

    get isBuilderMode() {
        return !this.isDetailMode;
    }

    get promotionId() {
        return this.isDetailMode ? this.recordId : this.createdPromotionId;
    }

    get candidateStageId() {
        return this.isDetailMode ? undefined : this.selectedStageId;
    }

    get cardTitle() {
        if (this.isDetailMode) {
            return this.promotionView ? `Promotion ${this.promotionView.name}` : 'Promotion';
        }
        return 'Promote work items';
    }

    get showStagePicker() {
        return !this.hideStagePicker;
    }

    get stageOptions() {
        return this.stageOptionsData.map((s) => ({ label: s.label, value: s.id }));
    }

    get hasStages() {
        return this.stageOptionsData.length > 0 || !!this.selectedStageId;
    }

    get noStageChosen() {
        return !this.selectedStageId;
    }

    get candidates() {
        return (this.candidateView ? this.candidateView.candidates : []).map((c) => ({
            ...c,
            url: recordUrl(c.workItemId, 'CDO_Work_Item__c'),
            statusLabel: labelOf(c.status),
            coverageLabel: formatPercent(c.coverage)
        }));
    }

    get hasCandidates() {
        return this.candidates.length > 0;
    }

    get ineligible() {
        return (this.candidateView ? this.candidateView.ineligible : []).map((c) => ({
            ...c,
            url: recordUrl(c.workItemId, 'CDO_Work_Item__c')
        }));
    }

    get hasIneligible() {
        return this.ineligible.length > 0;
    }

    get candidateSourceLabel() {
        if (!this.candidateView) {
            return '';
        }
        if (this.candidateView.isEntry) {
            return 'Approved work items that are not in the pipeline yet.';
        }
        return this.candidateView.previousStageName
            ? `Work items currently in ${this.candidateView.previousStageName}.`
            : 'This stage has no stage before it.';
    }

    get productionMessage() {
        return this.candidateView && this.candidateView.isProduction ? this.candidateView.message : null;
    }

    get showEntryGateNote() {
        return this.candidateView && this.candidateView.isEntry && !this.candidateView.canApproveEntry;
    }

    get selectedCount() {
        return this.selectedIds.length;
    }

    get selectionLabel() {
        const n = this.selectedIds.length;
        return n === 1 ? '1 work item selected' : `${n} work items selected`;
    }

    get promoteDisabled() {
        return this.working || this.selectedIds.length === 0;
    }

    get showSpecifiedTests() {
        return this.testLevel === 'RunSpecifiedTests';
    }

    // Promotion detail ---------------------------------------------------------------------

    get hasPromotion() {
        return !!this.promotionView;
    }

    get promotionStatusClass() {
        return this.promotionView ? statusBadgeClass(this.promotionView.status) : '';
    }

    get promotionStatusLabel() {
        return this.promotionView ? labelOf(this.promotionView.status) : '';
    }

    get promotionRoute() {
        if (!this.promotionView) {
            return '';
        }
        const from = this.promotionView.sourceStageName || 'Backlog';
        return `${from} → ${this.promotionView.targetStageName || ''}`;
    }

    get promotionUrl() {
        return this.promotionView ? recordUrl(this.promotionView.id, 'CDO_Promotion__c') : null;
    }

    get showRunPending() {
        return this.promotionView && this.promotionView.status === 'Dispatched' && !this.promotionView.runUrl;
    }

    get junctionRows() {
        return (this.promotionView ? this.promotionView.workItems : []).map((j) => ({
            ...j,
            url: recordUrl(j.workItemId, 'CDO_Work_Item__c'),
            statusLabel: labelOf(j.status),
            workItemStatusLabel: labelOf(j.workItemStatus)
        }));
    }

    get hasJunctionRows() {
        return this.junctionRows.length > 0;
    }

    get deploymentRows() {
        return (this.promotionView ? this.promotionView.deployments : []).map((d) => ({
            ...d,
            url: recordUrl(d.id, 'CDO_Deployment__c'),
            statusLabel: labelOf(d.status),
            kindLabel: d.checkOnly ? 'Validation' : labelOf(d.eventType),
            coverageLabel: formatPercent(d.coveragePercent),
            whenLabel: formatDateTime(d.completedOn || d.createdDate)
        }));
    }

    get hasDeployments() {
        return this.deploymentRows.length > 0;
    }

    get approvals() {
        return (this.promotionView ? this.promotionView.approvals : []).map((a) => ({
            ...a,
            decisionClass: statusBadgeClass(a.Decision__c),
            decisionLabel: labelOf(a.Decision__c),
            whenLabel: formatDateTime(a.Decided_On__c || a.CreatedDate)
        }));
    }

    get hasApprovals() {
        return this.approvals.length > 0;
    }

    get canDeploy() {
        return this.promotionView && this.promotionView.canDeploy;
    }

    get canCancel() {
        return this.promotionView && this.promotionView.canCancel;
    }

    get deployDisabled() {
        return this.working || !this.canDeploy;
    }

    get cancelDisabled() {
        return this.working || !this.canCancel;
    }

    // -----------------------------------------------------------------------------------------
    // Handlers
    // -----------------------------------------------------------------------------------------

    handleStageChange(event) {
        this.selectedStageId = event.detail.value;
        this.selectedIds = [];
        this.createdPromotionId = undefined;
    }

    handleRowSelection(event) {
        this.selectedIds = event.detail.selectedRows.map((r) => r.workItemId);
    }

    handleTestLevelChange(event) {
        this.testLevel = event.detail.value;
    }

    handleSpecifiedTestsChange(event) {
        this.specifiedTests = event.detail.value;
    }

    handleCheckOnlyChange(event) {
        this.checkOnly = event.detail.checked;
    }

    handlePromote() {
        this.submit(false);
    }

    handlePromoteAndDeploy() {
        this.submit(true);
    }

    async submit(deploy) {
        if (this.selectedIds.length === 0) {
            return;
        }
        const options = { direction: 'Forward' };
        if (this.testLevel) {
            options.testLevel = this.testLevel;
        }
        if (this.showSpecifiedTests && this.specifiedTests) {
            options.specifiedTests = this.specifiedTests;
        }
        if (this.checkOnly) {
            options.checkOnly = 'true';
        }
        this.working = true;
        try {
            const result = await createPromotion({
                workItemIds: this.selectedIds,
                targetStageId: this.selectedStageId,
                deploy,
                options
            });
            showToast(this, deploy ? 'Promotion queued' : 'Promotion created', result.message, 'success');
            this.createdPromotionId = result.promotionId;
            this.selectedIds = [];
            this.dispatchEvent(new CustomEvent('promoted', { detail: { ...result } }));
            await refreshAll(this.candidatesResult);
        } catch (e) {
            showError(this, 'Could not promote', e);
        } finally {
            this.working = false;
        }
    }

    async handleDeploy() {
        this.working = true;
        try {
            const result = await deployPromotion({ promotionId: this.promotionId });
            showToast(this, 'Promotion queued', result.message, 'success');
            await refreshAll(this.promotionResult);
            this.dispatchEvent(new CustomEvent('promoted', { detail: { ...result } }));
        } catch (e) {
            showError(this, 'Could not deploy the promotion', e);
        } finally {
            this.working = false;
        }
    }

    async handleCancel() {
        this.working = true;
        try {
            const result = await cancelPromotion({ promotionId: this.promotionId });
            showToast(this, 'Promotion cancelled', result.message, 'success');
            await refreshAll(this.promotionResult, this.candidatesResult);
        } catch (e) {
            showError(this, 'Could not cancel the promotion', e);
        } finally {
            this.working = false;
        }
    }

    async handleRefresh() {
        try {
            await refreshAll(this.promotionResult, this.candidatesResult);
        } catch (e) {
            showError(this, 'Could not refresh', e);
        }
    }

    handleOpenPromotion(event) {
        event.preventDefault();
        if (this.promotionView) {
            this[NavigationMixin.Navigate](recordPageRef(this.promotionView.id, 'CDO_Promotion__c'));
        }
    }

    // -----------------------------------------------------------------------------------------
    // Polling while the promotion is queued or running
    // -----------------------------------------------------------------------------------------

    syncPolling() {
        const live = this.promotionView && this.promotionView.inFlight;
        if (live && !this.pollTimer) {
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this.pollTimer = setInterval(() => {
                refreshAll(this.promotionResult).catch(() => this.stopPolling());
            }, POLL_MS);
        } else if (!live) {
            this.stopPolling();
        }
    }

    stopPolling() {
        if (this.pollTimer) {
            clearInterval(this.pollTimer);
            this.pollTimer = undefined;
        }
    }
}
