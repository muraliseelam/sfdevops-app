import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getState from '@salesforce/apex/CDOWorkItemCommandCenter.getState';
import performAction from '@salesforce/apex/CDOWorkItemCommandCenter.performAction';
import {
    errorMessage,
    formatDateTime,
    formatPercent,
    formatRelative,
    labelOf,
    recordPageRef,
    recordUrl,
    refreshAll,
    showError,
    showToast,
    statusBadgeClass
} from 'c/cdoUtils';

const POLL_MS = 15000;
const LIVE_PROMOTION = ['Queued', 'Dispatched', 'Deploying'];

const ACTIONS = [
    { name: 'commit', label: 'Commit', icon: 'utility:merge', variant: 'neutral' },
    { name: 'openPr', label: 'Open pull request', icon: 'utility:share', variant: 'neutral' },
    { name: 'validate', label: 'Validate', icon: 'utility:check', variant: 'neutral' },
    { name: 'promote', label: 'Promote', icon: 'utility:forward', variant: 'neutral' },
    { name: 'promoteAndDeploy', label: 'Promote & Deploy', icon: 'utility:upload', variant: 'brand' }
];

const ACTION_DONE_TITLE = {
    openPr: 'Pull request requested',
    validate: 'Validation requested',
    promote: 'Draft promotion created',
    promoteAndDeploy: 'Promotion queued',
    dispatchPromotion: 'Promotion queued'
};

/**
 * The work item at a glance: where it is in the pipeline, its status, coverage and pull request,
 * the actions it is ready for (from CDOWorkItemCommandCenter.availableActions), and a timeline of
 * its commits, promotions, deployments and approvals.
 */
export default class CdoWorkItemCommandCenter extends NavigationMixin(LightningElement) {
    @api recordId;

    state;
    error;
    working = false;
    showCommit = false;
    stateResult;
    pollTimer;

    @wire(getState, { workItemId: '$recordId' })
    wiredState(result) {
        this.stateResult = result;
        if (result.data) {
            this.state = result.data;
            this.error = undefined;
            this.syncPolling();
        } else if (result.error) {
            this.error = errorMessage(result.error);
            this.stopPolling();
        }
    }

    disconnectedCallback() {
        this.stopPolling();
    }

    // -----------------------------------------------------------------------------------------
    // Header and status
    // -----------------------------------------------------------------------------------------

    get hasRecord() {
        return !!this.recordId;
    }

    get isLoading() {
        return this.hasRecord && !this.state && !this.error;
    }

    get wi() {
        return this.state ? this.state.workItem || {} : {};
    }

    get title() {
        return this.state ? `${this.wi.Name}: ${this.wi.Subject__c || ''}` : 'Work item';
    }

    get badges() {
        const wi = this.wi;
        const list = [
            { key: 'status', label: 'Status', value: wi.Status__c },
            { key: 'merge', label: 'Merge', value: wi.Merge_State__c },
            { key: 'review', label: 'Review', value: wi.Review_State__c },
            { key: 'validation', label: 'Validation', value: wi.Last_Validation_Status__c }
        ];
        return list
            .filter((b) => b.value)
            .map((b) => ({ ...b, text: `${b.label}: ${labelOf(b.value)}`, className: statusBadgeClass(b.value) }));
    }

    get isBlocked() {
        return this.wi.Status__c === 'Blocked' && !!this.wi.Blocked_Reason__c;
    }

    get conflictPaths() {
        return this.wi.Conflict_Paths__c ? this.wi.Conflict_Paths__c.split('\n').filter((p) => p.trim()) : [];
    }

    get hasConflicts() {
        return this.conflictPaths.length > 0;
    }

    get dispatchWarning() {
        return this.state && this.state.dispatchEnabled === false ? this.state.dispatchMessage : null;
    }

    // Path -------------------------------------------------------------------------------------

    get pathSteps() {
        const steps = (this.state && this.state.path) || [];
        return [{ label: 'Backlog', value: 'backlog' }, ...steps.map((s) => ({ label: s.name, value: s.stageId }))];
    }

    get currentStep() {
        return (this.state && this.state.currentStageId) || 'backlog';
    }

    get hasPath() {
        return this.state && this.state.path && this.state.path.length > 0;
    }

    get pathSummary() {
        if (!this.state) {
            return '';
        }
        const here = this.state.currentStageName || 'the backlog';
        return this.state.nextStageName ? `In ${here}. Next: ${this.state.nextStageName}.` : `In ${here}.`;
    }

    // Quality and source -----------------------------------------------------------------------

    get coverageLabel() {
        return this.wi.Last_Coverage__c !== undefined && this.wi.Last_Coverage__c !== null ? formatPercent(this.wi.Last_Coverage__c) : 'Not measured';
    }

    get coverageValue() {
        const v = Number(this.wi.Last_Coverage__c);
        return Number.isNaN(v) ? 0 : Math.max(0, Math.min(100, v));
    }

    get hasCoverage() {
        return this.wi.Last_Coverage__c !== undefined && this.wi.Last_Coverage__c !== null;
    }

    get minimumLabel() {
        return this.wi.Minimum_Coverage__c !== undefined && this.wi.Minimum_Coverage__c !== null
            ? `minimum ${formatPercent(this.wi.Minimum_Coverage__c)}`
            : 'no work item minimum';
    }

    get coverageBelow() {
        const min = this.wi.Minimum_Coverage__c;
        return min !== undefined && min !== null && this.hasCoverage && Number(this.wi.Last_Coverage__c) < Number(min);
    }

    get prLabel() {
        return this.wi.Pull_Request_Number__c ? `Pull request #${this.wi.Pull_Request_Number__c}` : 'Pull request';
    }

    get prApprovedLabel() {
        return this.wi.Pull_Requests_Approved__c ? 'Approved' : 'Not approved yet';
    }

    get prApprovedClass() {
        return statusBadgeClass(this.wi.Pull_Requests_Approved__c ? 'Approved' : 'Pending') + ' slds-m-left_x-small';
    }

    get branchUrl() {
        return this.state && this.state.repoUrl && this.state.featureBranch
            ? `${this.state.repoUrl}/tree/${encodeURI(this.state.featureBranch)}`
            : null;
    }

    get lastRunUrl() {
        return this.wi.Last_Run_URL__c;
    }

    // Actions ----------------------------------------------------------------------------------

    get actions() {
        const available = (this.state && this.state.availableActions) || {};
        const reasons = (this.state && this.state.actionReasons) || {};
        return ACTIONS.map((a) => ({
            ...a,
            disabled: this.working || available[a.name] !== true,
            title: available[a.name] === true ? a.label : reasons[a.name] || `${a.label} is not available`
        }));
    }

    get unavailableReasons() {
        const available = (this.state && this.state.availableActions) || {};
        const reasons = (this.state && this.state.actionReasons) || {};
        return ACTIONS.filter((a) => available[a.name] !== true && reasons[a.name]).map((a) => ({
            key: a.name,
            text: `${a.label}: ${reasons[a.name]}`
        }));
    }

    get hasUnavailable() {
        return this.unavailableReasons.length > 0;
    }

    get openPromotion() {
        if (!this.state || !this.state.openPromotionId) {
            return null;
        }
        return {
            id: this.state.openPromotionId,
            name: this.state.openPromotionName,
            status: this.state.openPromotionStatus,
            statusLabel: labelOf(this.state.openPromotionStatus),
            statusClass: statusBadgeClass(this.state.openPromotionStatus),
            url: recordUrl(this.state.openPromotionId, 'CDO_Promotion__c'),
            isDraft: this.state.openPromotionStatus === 'Draft',
            deployLabel: `Deploy ${this.state.openPromotionName}`
        };
    }

    get deployDraftDisabled() {
        return this.working || (this.state && this.state.dispatchEnabled === false);
    }

    // Timeline ---------------------------------------------------------------------------------

    get timeline() {
        if (!this.state) {
            return [];
        }
        const items = [];
        (this.state.commits || []).forEach((c) =>
            items.push({
                key: `c-${c.Id}`,
                icon: 'utility:merge',
                kind: 'Commit',
                when: c.Committed_On__c || c.CreatedDate,
                title: c.Message__c ? c.Message__c.split('\n')[0] : c.Name,
                detail: [c.SHA__c ? c.SHA__c.substring(0, 7) : null, c.Committed_By__c, c.Component_Count__c ? `${c.Component_Count__c} components` : null]
                    .filter(Boolean)
                    .join(' · '),
                url: recordUrl(c.Id, 'CDO_Commit__c'),
                runUrl: c.Workflow_Run_URL__c
            })
        );
        (this.state.promotions || []).forEach((p) =>
            items.push({
                key: `p-${p.promotionId}`,
                icon: 'utility:forward',
                kind: 'Promotion',
                when: p.completedOn || p.dispatchedOn || p.createdDate,
                title: `${p.name}: ${p.sourceStageName || 'Backlog'} → ${p.targetStageName || ''}`,
                detail: p.message || (p.direction === 'Back' ? 'Back-promotion' : ''),
                status: p.status,
                url: recordUrl(p.promotionId, 'CDO_Promotion__c'),
                runUrl: p.runUrl
            })
        );
        (this.state.deployments || []).forEach((d) =>
            items.push({
                key: `d-${d.Id}`,
                icon: 'utility:upload',
                kind: d.Check_Only__c ? 'Validation' : labelOf(d.Event_Type__c) || 'Deployment',
                when: d.Completed_On__c || d.Started_On__c || d.CreatedDate,
                title: `${d.Name}${d.Stage__r ? ' to ' + d.Stage__r.Name : ''}`,
                detail: [
                    d.Coverage_Percent__c !== undefined && d.Coverage_Percent__c !== null ? `coverage ${formatPercent(d.Coverage_Percent__c)}` : null,
                    d.Message__c
                ]
                    .filter(Boolean)
                    .join(' · '),
                status: d.Status__c,
                url: recordUrl(d.Id, 'CDO_Deployment__c'),
                runUrl: d.Workflow_Run_URL__c
            })
        );
        (this.state.approvals || []).forEach((a) =>
            items.push({
                key: `a-${a.Id}`,
                icon: 'utility:approval',
                kind: 'Approval',
                when: a.Decided_On__c || a.CreatedDate,
                title: `${labelOf(a.Decision__c) || 'Decision'} by ${a.Approver__c || 'someone'}${a.Stage__r ? ' for ' + a.Stage__r.Name : ''}`,
                detail: [labelOf(a.Method__c), a.Comments__c].filter(Boolean).join(' · '),
                status: a.Decision__c,
                url: recordUrl(a.Id, 'CDO_Approval__c'),
                runUrl: a.Source_URL__c
            })
        );
        return items
            .sort((x, y) => new Date(y.when || 0).getTime() - new Date(x.when || 0).getTime())
            .map((i) => ({
                ...i,
                whenLabel: formatRelative(i.when),
                whenTitle: formatDateTime(i.when),
                hasStatus: !!i.status,
                statusLabel: labelOf(i.status),
                statusClass: statusBadgeClass(i.status) + ' slds-m-left_x-small'
            }));
    }

    get hasTimeline() {
        return this.timeline.length > 0;
    }

    get componentCount() {
        return this.state && this.state.components ? this.state.components.length : 0;
    }

    // -----------------------------------------------------------------------------------------
    // Handlers
    // -----------------------------------------------------------------------------------------

    handleRefresh() {
        refreshAll(this.stateResult).catch((e) => showError(this, 'Could not refresh', e));
    }

    handleAction(event) {
        const name = event.currentTarget.dataset.action;
        if (name === 'commit') {
            this.showCommit = true;
            return;
        }
        this.run(name, {});
    }

    handleDeployDraft() {
        this.run('dispatchPromotion', { promotionId: this.state.openPromotionId });
    }

    async run(action, params) {
        this.working = true;
        try {
            const result = await performAction({ workItemId: this.recordId, action, paramsJson: JSON.stringify(params || {}) });
            showToast(this, ACTION_DONE_TITLE[action] || 'Done', result.message, 'success');
            await refreshAll(this.stateResult);
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
        } catch (e) {
            showError(this, 'Could not complete the action', e);
        } finally {
            this.working = false;
        }
    }

    handleCloseCommit() {
        this.showCommit = false;
        this.handleRefresh();
    }

    handleModalKeydown(event) {
        if (event.key === 'Escape') {
            this.handleCloseCommit();
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

    // -----------------------------------------------------------------------------------------
    // Polling while something is running for this work item
    // -----------------------------------------------------------------------------------------

    get isLive() {
        if (!this.state) {
            return false;
        }
        const wi = this.wi;
        return (
            LIVE_PROMOTION.includes(this.state.openPromotionStatus) ||
            wi.Last_Validation_Status__c === 'Running' ||
            wi.Source_Changes_Status__c === 'Requested'
        );
    }

    syncPolling() {
        if (this.isLive && !this.pollTimer) {
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this.pollTimer = setInterval(() => {
                refreshAll(this.stateResult).catch(() => this.stopPolling());
            }, POLL_MS);
        } else if (!this.isLive) {
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
