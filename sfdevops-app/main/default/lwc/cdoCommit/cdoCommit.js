import { LightningElement, api, wire } from 'lwc';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getWorkItem from '@salesforce/apex/WorkItemController.getWorkItem';
import getSourceOrgs from '@salesforce/apex/WorkItemController.getSourceOrgs';
import requestListChanges from '@salesforce/apex/GitController.requestListChanges';
import getListChanges from '@salesforce/apex/GitController.getListChanges';
import commitComponents from '@salesforce/apex/GitController.commitComponents';
import {
    createPoller,
    errorMessage,
    formatDateTime,
    formatRelative,
    labelOf,
    showError,
    showToast,
    statusBadgeClass
} from 'c/cdoUtils';

const POLL_MS = 5000;
const POLL_ATTEMPTS = 72; // six minutes

const COLUMNS = [
    { label: 'Type', fieldName: 'type', sortable: true, initialWidth: 170 },
    { label: 'Name', fieldName: 'name', sortable: true, wrapText: true },
    { label: 'Change', fieldName: 'stateLabel', sortable: true, initialWidth: 100 },
    {
        label: 'Last Modified',
        fieldName: 'lastModifiedDate',
        type: 'date',
        sortable: true,
        initialWidth: 180,
        typeAttributes: { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' }
    },
    { label: 'Last Modified By', fieldName: 'lastModifiedBy', sortable: true, initialWidth: 170 },
    { label: 'On work item', fieldName: 'alreadyCommitted', type: 'boolean', initialWidth: 110 }
];

/**
 * Commit from a source org: list its changed metadata (newest first), select components, write a
 * message and commit them to the work item's feature branch.
 */
export default class CdoCommit extends LightningElement {
    @api recordId;

    workItem;
    sourceOrgs = [];
    sourceOrg;
    changes;
    loadError;
    members = [];
    selectedKeys = [];
    filterText = '';
    typeFilter = '';
    message = '';
    messageTouched = false;
    sortedBy = 'lastModifiedDate';
    sortedDirection = 'desc';
    requesting = false;
    committing = false;
    polling = false;

    columns = COLUMNS;
    poller;

    @wire(getWorkItem, { workItemId: '$recordId' })
    wiredWorkItem({ data, error }) {
        if (data) {
            this.workItem = data;
            if (!this.sourceOrg && data.Source_Org_Alias__c) {
                this.sourceOrg = data.Source_Org_Alias__c;
            }
            if (!this.messageTouched) {
                this.message = `${data.Name}: ${data.Subject__c || ''}`.trim();
            }
        } else if (error) {
            this.loadError = errorMessage(error);
        }
    }

    @wire(getSourceOrgs)
    wiredSourceOrgs({ data }) {
        if (data) {
            this.sourceOrgs = data;
            if (!this.sourceOrg && data.length === 1) {
                this.sourceOrg = data[0].Pipeline_Key__c;
            }
        }
    }

    connectedCallback() {
        this.poller = createPoller(() => this.loadChanges(true), {
            intervalMs: POLL_MS,
            maxAttempts: POLL_ATTEMPTS,
            onTimeout: () => {
                this.polling = false;
                showToast(
                    this,
                    'Still waiting for the source org',
                    'The change list has not arrived yet. The workflow may still be running; refresh in a minute, or check the run in GitHub.',
                    'warning'
                );
            },
            onError: (e) => {
                this.polling = false;
                showError(this, 'Could not read the change list', e);
            }
        });
        if (this.recordId) {
            this.loadChanges(false);
        }
    }

    disconnectedCallback() {
        if (this.poller) {
            this.poller.stop();
        }
    }

    // -----------------------------------------------------------------------------------------
    // View state
    // -----------------------------------------------------------------------------------------

    get hasRecord() {
        return !!this.recordId;
    }

    get sourceOrgOptions() {
        return this.sourceOrgs.map((o) => ({
            label: o.Pipeline_Key__c && o.Pipeline_Key__c !== o.Name ? `${o.Name} (${o.Pipeline_Key__c})` : o.Name,
            value: o.Pipeline_Key__c || o.Org_Alias__c || o.Name
        }));
    }

    get hasSourceOrgs() {
        return this.sourceOrgs.length > 0;
    }

    get listDisabled() {
        return this.requesting || this.polling || !this.sourceOrg;
    }

    get status() {
        return this.changes ? this.changes.status : 'Idle';
    }

    get statusLabel() {
        return this.polling ? 'Waiting for the source org' : labelOf(this.status);
    }

    get statusClass() {
        return statusBadgeClass(this.polling ? 'Requested' : this.status);
    }

    get receivedLabel() {
        return this.changes && this.changes.receivedOn ? formatRelative(this.changes.receivedOn) : '';
    }

    get receivedTitle() {
        return this.changes ? formatDateTime(this.changes.receivedOn) : '';
    }

    get changesMessage() {
        return this.changes ? this.changes.message : null;
    }

    get typeOptions() {
        const types = [...new Set(this.members.map((m) => m.type))].sort();
        return [{ label: 'All types', value: '' }, ...types.map((t) => ({ label: t, value: t }))];
    }

    get visibleMembers() {
        const text = this.filterText.trim().toLowerCase();
        let rows = this.members.filter(
            (m) =>
                (!this.typeFilter || m.type === this.typeFilter) &&
                (!text || m.name.toLowerCase().includes(text) || (m.lastModifiedBy || '').toLowerCase().includes(text))
        );
        const field = this.sortedBy;
        const dir = this.sortedDirection === 'asc' ? 1 : -1;
        rows = [...rows].sort((a, b) => {
            const x = (a[field] || '').toString().toLowerCase();
            const y = (b[field] || '').toString().toLowerCase();
            if (x === y) {
                return a.key < b.key ? -1 : 1;
            }
            return x < y ? -dir : dir;
        });
        return rows;
    }

    get hasMembers() {
        return this.members.length > 0;
    }

    get hasVisibleMembers() {
        return this.visibleMembers.length > 0;
    }

    get countLabel() {
        const shown = this.visibleMembers.length;
        const total = this.members.length;
        return shown === total ? `${total} changed component${total === 1 ? '' : 's'}` : `${shown} of ${total} shown`;
    }

    get selectionLabel() {
        const n = this.selectedKeys.length;
        return n === 1 ? '1 component selected' : `${n} components selected`;
    }

    get commitDisabled() {
        return this.committing || this.selectedKeys.length === 0 || !this.message.trim();
    }

    get emptyText() {
        if (this.polling) {
            return 'Listing changes in the source org. This usually takes a minute.';
        }
        if (this.status === 'Failed') {
            return 'The source org could not be read. Check the run in GitHub, then list changes again.';
        }
        if (this.status === 'Received') {
            return 'The source org reported no changes.';
        }
        return 'Choose a source org and list its changes.';
    }

    // -----------------------------------------------------------------------------------------
    // Handlers
    // -----------------------------------------------------------------------------------------

    handleSourceOrgChange(event) {
        this.sourceOrg = event.detail.value;
    }

    async handleListChanges() {
        this.requesting = true;
        try {
            await requestListChanges({ workItemId: this.recordId, sourceOrg: this.sourceOrg });
            showToast(this, 'Listing changes', `Asked ${this.sourceOrg} for its changed metadata.`, 'info');
            this.polling = true;
            this.changes = { ...(this.changes || {}), status: 'Requested' };
            this.poller.start();
        } catch (e) {
            showError(this, 'Could not list changes', e);
        } finally {
            this.requesting = false;
        }
    }

    /** Reads the stored change list. Returns true when polling can stop. */
    async loadChanges(fromPoll) {
        const result = await getListChanges({ workItemId: this.recordId });
        const settled = result.status === 'Received' || result.status === 'Failed';
        if (!fromPoll || settled) {
            this.applyChanges(result);
        }
        if (fromPoll && settled) {
            this.polling = false;
            if (result.status === 'Received') {
                showToast(this, 'Changes received', `${result.total} changed component${result.total === 1 ? '' : 's'} listed.`, 'success');
            } else {
                showToast(this, 'Listing changes failed', result.message || 'Check the workflow run in GitHub.', 'error', 'sticky');
            }
        }
        if (!fromPoll && result.status === 'Requested' && !this.polling) {
            // A request is already outstanding (for example from another tab): keep watching it.
            this.polling = true;
            this.poller.start();
        }
        return settled;
    }

    applyChanges(result) {
        this.changes = result;
        this.members = (result.members || []).map((m) => ({ ...m, stateLabel: labelOf(m.state) }));
        const keys = new Set(this.members.map((m) => m.key));
        this.selectedKeys = this.selectedKeys.filter((k) => keys.has(k));
    }

    handleRefresh() {
        this.loadChanges(false).catch((e) => showError(this, 'Could not read the change list', e));
    }

    handleFilterChange(event) {
        this.filterText = event.detail.value || '';
    }

    handleTypeFilterChange(event) {
        this.typeFilter = event.detail.value;
    }

    handleSort(event) {
        this.sortedBy = event.detail.fieldName;
        this.sortedDirection = event.detail.sortDirection;
    }

    handleRowSelection(event) {
        // The table only reports rows it shows; keep selections hidden by the filter.
        const visible = new Set(this.visibleMembers.map((m) => m.key));
        const kept = this.selectedKeys.filter((k) => !visible.has(k));
        this.selectedKeys = [...kept, ...event.detail.selectedRows.map((r) => r.key)];
    }

    handleClearSelection() {
        this.selectedKeys = [];
    }

    handleMessageChange(event) {
        this.message = event.detail.value || '';
        this.messageTouched = true;
    }

    async handleCommit() {
        const chosen = this.members.filter((m) => this.selectedKeys.includes(m.key)).map((m) => ({ type: m.type, name: m.name }));
        if (!chosen.length) {
            return;
        }
        this.committing = true;
        try {
            const message = await commitComponents({
                workItemId: this.recordId,
                componentsJson: JSON.stringify(chosen),
                message: this.message.trim()
            });
            showToast(this, 'Commit requested', message, 'success');
            this.selectedKeys = [];
            notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
        } catch (e) {
            showError(this, 'Could not commit', e);
        } finally {
            this.committing = false;
        }
    }
}
