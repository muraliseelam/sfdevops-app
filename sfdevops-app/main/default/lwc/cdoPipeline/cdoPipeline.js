import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getProjects from '@salesforce/apex/PipelineController.getProjects';
import getPipeline from '@salesforce/apex/PipelineController.getPipeline';
import {
    errorMessage,
    formatDateTime,
    formatPercent,
    formatRelative,
    healthBadge,
    labelOf,
    recordPageRef,
    recordUrl,
    refreshAll,
    showToast,
    statusBadgeClass
} from 'c/cdoUtils';

const POLL_MS = 20000;

/**
 * The pipeline at a glance: one card per stage, left to right, with environment health,
 * work-item counts, in-flight promotions, the latest deployment and a Promote button.
 */
export default class CdoPipeline extends NavigationMixin(LightningElement) {
    projectId = null;
    projects = [];
    pipeline;
    error;
    isLoading = true;
    promoteStage;

    wiredPipelineResult;
    pollTimer;

    @wire(getProjects)
    wiredProjects({ data, error }) {
        if (data) {
            this.projects = data;
        } else if (error) {
            this.projects = [];
        }
    }

    @wire(getPipeline, { projectId: '$projectId' })
    wiredPipeline(result) {
        this.wiredPipelineResult = result;
        const { data, error } = result;
        if (data) {
            this.pipeline = data;
            this.error = undefined;
            this.isLoading = false;
            this.syncPolling();
        } else if (error) {
            this.error = errorMessage(error);
            this.pipeline = undefined;
            this.isLoading = false;
            this.stopPolling();
        }
    }

    disconnectedCallback() {
        this.stopPolling();
    }

    // -----------------------------------------------------------------------------------------
    // View state
    // -----------------------------------------------------------------------------------------

    get showProjectPicker() {
        return this.projects.length > 1;
    }

    get projectOptions() {
        return this.projects.map((p) => ({ label: p.Name, value: p.Id }));
    }

    get selectedProjectId() {
        return this.projectId || (this.pipeline && this.pipeline.projectId);
    }

    get emptyMessage() {
        return this.pipeline && !this.pipeline.hasStages ? this.pipeline.emptyMessage : null;
    }

    get hasPipeline() {
        return this.pipeline && this.pipeline.hasStages;
    }

    get projectName() {
        return this.pipeline ? this.pipeline.projectName : '';
    }

    get repoUrl() {
        return this.pipeline ? this.pipeline.repoUrl : null;
    }

    get repoLabel() {
        return this.pipeline ? this.pipeline.repository || this.pipeline.repoUrl : '';
    }

    get backlogCount() {
        return this.pipeline ? this.pipeline.backlogCount : 0;
    }

    get approvedBacklogCount() {
        return this.pipeline ? this.pipeline.approvedBacklogCount : 0;
    }

    get workItemListUrl() {
        return '/lightning/o/CDO_Work_Item__c/list';
    }

    get isPolling() {
        return !!this.pollTimer;
    }

    get stages() {
        if (!this.hasPipeline) {
            return [];
        }
        return this.pipeline.stages.map((s) => {
            const health = healthBadge(s.healthStatus);
            const latest = s.latestDeployment;
            return {
                ...s,
                key: s.stageId,
                headingId: `stage-${s.stageId}`,
                stageUrl: recordUrl(s.stageId, 'CDO_Stage__c'),
                environmentUrl: recordUrl(s.environmentId, 'CDO_Environment__c'),
                healthLabel: health.label,
                healthClass: health.className,
                lastDeployedLabel: s.lastDeployedOn ? formatRelative(s.lastDeployedOn) : '',
                lastDeployedTitle: formatDateTime(s.lastDeployedOn),
                gateLabel: labelOf(s.gateType),
                coverageLabel: s.coverageFloor !== null && s.coverageFloor !== undefined ? formatPercent(s.coverageFloor, 0) : '',
                hasWorkItems: s.workItems && s.workItems.length > 0,
                moreWorkItems: s.workItemCount > (s.workItems ? s.workItems.length : 0)
                    ? s.workItemCount - s.workItems.length
                    : 0,
                workItems: (s.workItems || []).map((w) => ({
                    ...w,
                    url: recordUrl(w.id, 'CDO_Work_Item__c'),
                    statusLabel: labelOf(w.status),
                    statusClass: statusBadgeClass(w.status),
                    title: `${w.name}: ${w.subject || ''}`
                })),
                hasInFlight: s.inFlight && s.inFlight.length > 0,
                inFlight: (s.inFlight || []).map((p) => ({
                    ...p,
                    url: recordUrl(p.id, 'CDO_Promotion__c'),
                    statusLabel: labelOf(p.status),
                    statusClass: statusBadgeClass(p.status),
                    // Only the callback writes the run URL; Dispatched without one is unconfirmed.
                    unconfirmed: p.status === 'Dispatched' && !p.runUrl,
                    whenLabel: formatRelative(p.dispatchedOn || p.createdDate)
                })),
                hasLatest: !!latest,
                latest: latest
                    ? {
                          ...latest,
                          url: recordUrl(latest.id, 'CDO_Deployment__c'),
                          statusLabel: labelOf(latest.status),
                          statusClass: statusBadgeClass(latest.status),
                          kindLabel: latest.checkOnly ? 'Validation' : labelOf(latest.eventType) || 'Deploy',
                          subject: latest.workItemName || latest.promotionName || latest.releaseName || '',
                          whenLabel: formatRelative(latest.completedOn || latest.createdDate),
                          whenTitle: formatDateTime(latest.completedOn || latest.createdDate),
                          coverageLabel: formatPercent(latest.coveragePercent)
                      }
                    : null,
                promoteLabel: `Promote into ${s.name}`,
                showConnector: true
            };
        });
    }

    get promoteModalTitle() {
        return this.promoteStage ? `Promote into ${this.promoteStage.name}` : '';
    }

    // -----------------------------------------------------------------------------------------
    // Handlers
    // -----------------------------------------------------------------------------------------

    handleProjectChange(event) {
        this.projectId = event.detail.value;
        this.isLoading = true;
    }

    async handleRefresh() {
        try {
            await refreshAll(this.wiredPipelineResult);
        } catch (e) {
            showToast(this, 'Could not refresh the pipeline', errorMessage(e), 'error');
        }
    }

    handleNavigate(event) {
        const { id, object } = event.currentTarget.dataset;
        if (!id) {
            return;
        }
        event.preventDefault();
        this[NavigationMixin.Navigate](recordPageRef(id, object));
    }

    handleOpenWorkItems(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: 'CDO_Work_Item__c', actionName: 'list' },
            state: { filterName: 'Recent' }
        });
    }

    handleOpenReleaseBoard(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate]({ type: 'standard__navItemPage', attributes: { apiName: 'CDO_Release_Board' } });
    }

    handleOpenPromote(event) {
        const stageId = event.currentTarget.dataset.id;
        this.promoteStage = this.pipeline.stages.find((s) => s.stageId === stageId);
    }

    handleClosePromote() {
        this.promoteStage = undefined;
    }

    handleModalKeydown(event) {
        if (event.key === 'Escape') {
            this.handleClosePromote();
        }
    }

    handlePromoted() {
        this.handleRefresh();
    }

    // -----------------------------------------------------------------------------------------
    // Polling: refresh while anything is in flight, so status changes show without a reload.
    // -----------------------------------------------------------------------------------------

    syncPolling() {
        const anyInFlight = this.pipeline && (this.pipeline.stages || []).some((s) => s.inFlight && s.inFlight.length);
        if (anyInFlight && !this.pollTimer) {
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this.pollTimer = setInterval(() => {
                refreshAll(this.wiredPipelineResult).catch(() => this.stopPolling());
            }, POLL_MS);
        } else if (!anyInFlight) {
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
