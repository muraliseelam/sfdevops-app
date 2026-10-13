import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import LightningConfirm from 'lightning/confirm';
import getProjects from '@salesforce/apex/PipelineController.getProjects';
import getReleases from '@salesforce/apex/ReleaseController.getReleases';
import getAvailableWorkItems from '@salesforce/apex/ReleaseController.getAvailableWorkItems';
import createRelease from '@salesforce/apex/ReleaseController.createRelease';
import addWorkItems from '@salesforce/apex/ReleaseController.addWorkItems';
import removeWorkItem from '@salesforce/apex/ReleaseController.removeWorkItem';
import assembleRelease from '@salesforce/apex/ReleaseController.assembleRelease';
import releaseToProduction from '@salesforce/apex/ReleaseController.releaseToProduction';
import getContext from '@salesforce/apex/GovernanceController.getContext';
import {
    errorMessage,
    formatDate,
    formatDateTime,
    labelOf,
    recordPageRef,
    recordUrl,
    refreshAll,
    showError,
    showToast,
    statusBadgeClass
} from 'c/cdoUtils';

const STATUS_COLUMNS = ['Planned', 'Assembling', 'Ready', 'Validating', 'Releasing', 'Released', 'Failed'];

const WORK_ITEM_COLUMNS = [
    { label: 'Work item', fieldName: 'url', type: 'url', typeAttributes: { label: { fieldName: 'Name' }, target: '_self' }, initialWidth: 120 },
    { label: 'Subject', fieldName: 'Subject__c', wrapText: true },
    { label: 'Status', fieldName: 'statusLabel', initialWidth: 120 },
    { label: 'Stage', fieldName: 'stageName', initialWidth: 120 },
    { label: 'Developer', fieldName: 'developerName', initialWidth: 150 },
    {
        type: 'button-icon',
        initialWidth: 60,
        typeAttributes: {
            iconName: 'utility:close',
            name: 'remove',
            alternativeText: 'Remove from release',
            title: 'Remove from release',
            disabled: { fieldName: 'removeDisabled' }
        }
    }
];

const AVAILABLE_COLUMNS = [
    { label: 'Work item', fieldName: 'url', type: 'url', typeAttributes: { label: { fieldName: 'Name' }, target: '_self' }, initialWidth: 120 },
    { label: 'Subject', fieldName: 'Subject__c', wrapText: true },
    { label: 'Status', fieldName: 'statusLabel', initialWidth: 120 },
    { label: 'Stage', fieldName: 'stageName', initialWidth: 120 }
];

/**
 * Releases by status: create a release, add and remove work items, assemble the release branch
 * and start the production release.
 */
export default class CdoReleaseBoard extends NavigationMixin(LightningElement) {
    projectId;
    projects = [];
    releases = [];
    available = [];
    context;
    selectedReleaseId;
    selectedToAdd = [];
    showNewForm = false;
    newName = '';
    newTargetDate;
    working = false;
    error;
    isLoading = true;

    releasesResult;
    availableResult;

    workItemColumns = WORK_ITEM_COLUMNS;
    availableColumns = AVAILABLE_COLUMNS;

    @wire(getProjects)
    wiredProjects({ data }) {
        if (data) {
            this.projects = data;
            if (!this.projectId && data.length) {
                this.projectId = data[0].Id;
            }
            if (!data.length) {
                this.isLoading = false;
            }
        }
    }

    @wire(getReleases, { projectId: '$projectId' })
    wiredReleases(result) {
        this.releasesResult = result;
        if (result.data) {
            this.releases = result.data;
            this.error = undefined;
            this.isLoading = false;
        } else if (result.error) {
            this.error = errorMessage(result.error);
            this.isLoading = false;
        }
    }

    @wire(getAvailableWorkItems, { projectId: '$projectId' })
    wiredAvailable(result) {
        this.availableResult = result;
        if (result.data) {
            this.available = result.data;
        }
    }

    @wire(getContext)
    wiredContext({ data }) {
        if (data) {
            this.context = data;
        }
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

    get noProjects() {
        return !this.isLoading && this.projects.length === 0;
    }

    get hasReleases() {
        return this.releases.length > 0;
    }

    get columns() {
        return STATUS_COLUMNS.map((status) => {
            const items = this.releases
                .filter((r) => r.status === status)
                .map((r) => ({
                    ...r,
                    targetLabel: r.targetDate ? formatDate(r.targetDate) : 'No target date',
                    selected: r.id === this.selectedReleaseId,
                    tileClass: `release-tile slds-box slds-box_x-small slds-m-bottom_x-small${r.id === this.selectedReleaseId ? ' release-tile_selected' : ''}`,
                    ariaPressed: r.id === this.selectedReleaseId ? 'true' : 'false',
                    countLabel: `${r.workItemCount} work item${r.workItemCount === 1 ? '' : 's'}`
                }));
            return {
                status,
                label: labelOf(status),
                headingId: `col-${status}`,
                badgeClass: statusBadgeClass(status),
                count: items.length,
                items,
                isEmpty: items.length === 0
            };
        });
    }

    get selected() {
        return this.releases.find((r) => r.id === this.selectedReleaseId);
    }

    get selectedStatusClass() {
        return this.selected ? statusBadgeClass(this.selected.status) : '';
    }

    get selectedStatusLabel() {
        return this.selected ? labelOf(this.selected.status) : '';
    }

    get selectedUrl() {
        return this.selected ? recordUrl(this.selected.id, 'CDO_Release__c') : null;
    }

    get selectedTargetLabel() {
        return this.selected && this.selected.targetDate ? formatDate(this.selected.targetDate) : 'Not set';
    }

    get selectedReleasedLabel() {
        return this.selected && this.selected.releasedOn ? formatDateTime(this.selected.releasedOn) : '';
    }

    get selectedWorkItems() {
        if (!this.selected) {
            return [];
        }
        return this.selected.workItems.map((w) => ({
            ...w,
            url: recordUrl(w.Id, 'CDO_Work_Item__c'),
            statusLabel: labelOf(w.Status__c),
            stageName: w.Current_Stage__r ? w.Current_Stage__r.Name : 'Backlog',
            developerName: w.Developer__r ? w.Developer__r.Name : '',
            removeDisabled: this.selected.locked
        }));
    }

    get hasSelectedWorkItems() {
        return this.selectedWorkItems.length > 0;
    }

    get availableRows() {
        return this.available.map((w) => ({
            ...w,
            url: recordUrl(w.Id, 'CDO_Work_Item__c'),
            statusLabel: labelOf(w.Status__c),
            stageName: w.Current_Stage__r ? w.Current_Stage__r.Name : 'Backlog'
        }));
    }

    get hasAvailable() {
        return this.available.length > 0;
    }

    get canAddWorkItems() {
        return this.selected && !this.selected.locked;
    }

    get addDisabled() {
        return this.working || this.selectedToAdd.length === 0;
    }

    get addLabel() {
        const n = this.selectedToAdd.length;
        return n ? `Add ${n} to release` : 'Add to release';
    }

    get assembleDisabled() {
        return this.working || !this.selected || !this.selected.canAssemble;
    }

    get canRunProdRelease() {
        return this.context && this.context.canRunProdRelease;
    }

    get releaseDisabled() {
        return this.working || !this.selected || !this.selected.canRelease;
    }

    get releaseHint() {
        if (!this.selected) {
            return '';
        }
        if (!this.canRunProdRelease) {
            return 'Releasing to production needs the CDO_Run_Prod_Release permission.';
        }
        if (!this.selected.canRelease) {
            return 'Assemble the release first. It can go to production when it is Ready.';
        }
        return 'Validates against production first, then waits for the required reviewer in GitHub.';
    }

    get createDisabled() {
        return this.working || !this.newName.trim();
    }

    // -----------------------------------------------------------------------------------------
    // Handlers
    // -----------------------------------------------------------------------------------------

    handleProjectChange(event) {
        this.projectId = event.detail.value;
        this.selectedReleaseId = undefined;
    }

    handleRefresh() {
        refreshAll(this.releasesResult, this.availableResult).catch((e) => showError(this, 'Could not refresh', e));
    }

    handleSelectRelease(event) {
        const id = event.currentTarget.dataset.id;
        this.selectedReleaseId = this.selectedReleaseId === id ? undefined : id;
        this.selectedToAdd = [];
    }

    handleOpenRelease(event) {
        event.preventDefault();
        if (this.selected) {
            this[NavigationMixin.Navigate](recordPageRef(this.selected.id, 'CDO_Release__c'));
        }
    }

    toggleNewForm() {
        this.showNewForm = !this.showNewForm;
    }

    handleNewNameChange(event) {
        this.newName = event.detail.value || '';
    }

    handleNewDateChange(event) {
        this.newTargetDate = event.detail.value;
    }

    async handleCreate() {
        this.working = true;
        try {
            const id = await createRelease({ name: this.newName.trim(), projectId: this.projectId, targetDate: this.newTargetDate || null });
            showToast(this, 'Release created', `${this.newName.trim()} is planned.`, 'success');
            this.newName = '';
            this.newTargetDate = undefined;
            this.showNewForm = false;
            await refreshAll(this.releasesResult);
            this.selectedReleaseId = id;
        } catch (e) {
            showError(this, 'Could not create the release', e);
        } finally {
            this.working = false;
        }
    }

    handleAvailableSelection(event) {
        this.selectedToAdd = event.detail.selectedRows.map((r) => r.Id);
    }

    async handleAdd() {
        this.working = true;
        try {
            const added = await addWorkItems({ releaseId: this.selectedReleaseId, workItemIds: this.selectedToAdd });
            showToast(this, 'Work items added', `${added} work item${added === 1 ? '' : 's'} added to ${this.selected.name}.`, 'success');
            this.selectedToAdd = [];
            await refreshAll(this.releasesResult, this.availableResult);
        } catch (e) {
            showError(this, 'Could not add the work items', e);
        } finally {
            this.working = false;
        }
    }

    async handleRowAction(event) {
        if (event.detail.action.name !== 'remove') {
            return;
        }
        const row = event.detail.row;
        this.working = true;
        try {
            await removeWorkItem({ workItemId: row.Id });
            showToast(this, 'Work item removed', `${row.Name} removed from ${this.selected.name}.`, 'success');
            await refreshAll(this.releasesResult, this.availableResult);
        } catch (e) {
            showError(this, 'Could not remove the work item', e);
        } finally {
            this.working = false;
        }
    }

    async handleAssemble() {
        this.working = true;
        try {
            const message = await assembleRelease({ releaseId: this.selectedReleaseId });
            showToast(this, 'Assembling release', message, 'success');
            await refreshAll(this.releasesResult);
        } catch (e) {
            showError(this, 'Could not assemble the release', e);
        } finally {
            this.working = false;
        }
    }

    async handleReleaseToProduction() {
        const release = this.selected;
        const confirmed = await LightningConfirm.open({
            message: `Start the production release of ${release.name} (${release.workItemCount} work items from ${release.releaseBranch})? It validates against production, then waits for the required reviewer in GitHub before deploying.`,
            label: 'Release to production',
            theme: 'warning'
        });
        if (!confirmed) {
            return;
        }
        this.working = true;
        try {
            const message = await releaseToProduction({ releaseId: release.id });
            showToast(this, 'Production release started', message, 'success');
            await refreshAll(this.releasesResult);
        } catch (e) {
            showError(this, 'Could not start the production release', e);
        } finally {
            this.working = false;
        }
    }
}
