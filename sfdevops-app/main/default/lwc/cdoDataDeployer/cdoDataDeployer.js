import { LightningElement, wire } from 'lwc';
import LightningConfirm from 'lightning/confirm';
import getDataSets from '@salesforce/apex/DataController.getDataSets';
import getDataSet from '@salesforce/apex/DataController.getDataSet';
import getEnvironments from '@salesforce/apex/DataController.getEnvironments';
import saveTemplate from '@salesforce/apex/DataController.saveTemplate';
import deleteTemplate from '@salesforce/apex/DataController.deleteTemplate';
import deployDataSet from '@salesforce/apex/DataController.deployDataSet';
import { errorMessage, formatDateTime, labelOf, recordUrl, refreshAll, showError, showToast, statusBadgeClass } from 'c/cdoUtils';

const TEMPLATE_COLUMNS = [
    { label: 'Order', fieldName: 'Order__c', type: 'number', initialWidth: 80, cellAttributes: { alignment: 'left' } },
    { label: 'Template', fieldName: 'Name', initialWidth: 160 },
    { label: 'Object', fieldName: 'Object_API_Name__c', initialWidth: 160 },
    { label: 'Fields', fieldName: 'Fields__c', wrapText: true },
    { label: 'Filter', fieldName: 'Filter__c', wrapText: true },
    { label: 'External id', fieldName: 'External_Id_Field__c', initialWidth: 140 },
    { label: 'Limit', fieldName: 'Record_Limit__c', type: 'number', initialWidth: 80, cellAttributes: { alignment: 'left' } },
    {
        type: 'action',
        typeAttributes: {
            rowActions: [
                { label: 'Edit', name: 'edit' },
                { label: 'Delete', name: 'delete' }
            ]
        }
    }
];

/**
 * Records-not-metadata deployment: choose a data set, edit its templates (one object's
 * extraction rule each), and deploy it from one environment to another.
 */
export default class CdoDataDeployer extends LightningElement {
    dataSets = [];
    environments = [];
    selectedId;
    view;
    sourceEnv;
    targetEnv;
    editing;
    working = false;
    listError;
    detailError;

    dataSetsResult;
    detailResult;

    templateColumns = TEMPLATE_COLUMNS;

    @wire(getDataSets)
    wiredDataSets(result) {
        this.dataSetsResult = result;
        if (result.data) {
            this.dataSets = result.data;
            this.listError = undefined;
            if (!this.selectedId && result.data.length) {
                this.selectDataSet(result.data[0].Id);
            }
        } else if (result.error) {
            this.listError = errorMessage(result.error);
        }
    }

    @wire(getDataSet, { dataSetId: '$selectedId' })
    wiredDetail(result) {
        this.detailResult = result;
        if (result.data) {
            this.view = result.data;
            this.detailError = undefined;
            const ds = result.data.dataSet;
            if (ds) {
                if (!this.sourceEnv && ds.Source_Environment__r) {
                    this.sourceEnv = ds.Source_Environment__r.Pipeline_Key__c;
                }
                if (!this.targetEnv && ds.Target_Environment__r) {
                    this.targetEnv = ds.Target_Environment__r.Pipeline_Key__c;
                }
            }
        } else if (result.error) {
            this.detailError = errorMessage(result.error);
        }
    }

    @wire(getEnvironments)
    wiredEnvironments({ data }) {
        if (data) {
            this.environments = data;
        }
    }

    // -----------------------------------------------------------------------------------------
    // View state
    // -----------------------------------------------------------------------------------------

    get hasDataSets() {
        return this.dataSets.length > 0;
    }

    get dataSetItems() {
        return this.dataSets.map((ds) => ({
            id: ds.Id,
            name: ds.Name,
            statusLabel: labelOf(ds.Status__c),
            statusClass: statusBadgeClass(ds.Status__c),
            templateCount: ds.Data_Templates__r ? ds.Data_Templates__r.length : 0,
            className: `slds-button dataset-item${ds.Id === this.selectedId ? ' dataset-item_selected' : ''}`,
            ariaCurrent: ds.Id === this.selectedId ? 'true' : 'false'
        }));
    }

    get dataSet() {
        return this.view ? this.view.dataSet : null;
    }

    get dataSetUrl() {
        return this.dataSet ? recordUrl(this.dataSet.Id, 'CDO_Data_Set__c') : null;
    }

    get statusLabel() {
        return this.dataSet ? labelOf(this.dataSet.Status__c) : '';
    }

    get statusClass() {
        return this.dataSet ? statusBadgeClass(this.dataSet.Status__c) : '';
    }

    get lastDeployedLabel() {
        return this.dataSet && this.dataSet.Last_Deployed_On__c ? formatDateTime(this.dataSet.Last_Deployed_On__c) : 'Never';
    }

    get templates() {
        return this.view ? this.view.templates : [];
    }

    get hasTemplates() {
        return this.templates.length > 0;
    }

    get relationships() {
        return (this.view ? this.view.relationships : []).map((r) => ({
            id: r.Id,
            label: `${r.Parent_Template__r ? r.Parent_Template__r.Name : '?'} → ${r.Child_Template__r ? r.Child_Template__r.Name : '?'}`,
            field: r.Relationship_Field__c
        }));
    }

    get hasRelationships() {
        return this.relationships.length > 0;
    }

    get environmentOptions() {
        return this.environments.map((e) => ({
            label: `${e.Name} (${e.Pipeline_Key__c})`,
            value: e.Pipeline_Key__c
        }));
    }

    get deployDisabled() {
        return this.working || !this.hasTemplates || !this.sourceEnv || !this.targetEnv || this.sourceEnv === this.targetEnv
            || (this.dataSet && this.dataSet.Status__c === 'Deploying');
    }

    get deployHint() {
        if (!this.hasTemplates) {
            return 'Add at least one template before deploying.';
        }
        if (this.sourceEnv && this.sourceEnv === this.targetEnv) {
            return 'The source and target environments must differ.';
        }
        if (this.dataSet && this.dataSet.Status__c === 'Deploying') {
            return 'A deploy of this data set is running.';
        }
        return '';
    }

    get isEditing() {
        return !!this.editing;
    }

    get editorTitle() {
        return this.editing && this.editing.Id ? `Edit template ${this.editing.Name}` : 'New template';
    }

    // -----------------------------------------------------------------------------------------
    // Handlers
    // -----------------------------------------------------------------------------------------

    selectDataSet(id) {
        this.selectedId = id;
        this.editing = undefined;
        this.sourceEnv = undefined;
        this.targetEnv = undefined;
    }

    handleSelect(event) {
        this.selectDataSet(event.currentTarget.dataset.id);
    }

    handleRefresh() {
        refreshAll(this.dataSetsResult, this.detailResult).catch((e) => showError(this, 'Could not refresh', e));
    }

    handleSourceChange(event) {
        this.sourceEnv = event.detail.value;
    }

    handleTargetChange(event) {
        this.targetEnv = event.detail.value;
    }

    handleNewTemplate() {
        const nextOrder = this.templates.reduce((max, t) => Math.max(max, t.Order__c || 0), 0) + 1;
        this.editing = {
            Name: '',
            Object_API_Name__c: '',
            Fields__c: '',
            Filter__c: '',
            External_Id_Field__c: '',
            Order__c: nextOrder,
            Record_Limit__c: null
        };
    }

    handleRowAction(event) {
        const { action, row } = event.detail;
        if (action.name === 'edit') {
            this.editing = {
                Id: row.Id,
                Name: row.Name,
                Object_API_Name__c: row.Object_API_Name__c,
                Fields__c: row.Fields__c,
                Filter__c: row.Filter__c,
                External_Id_Field__c: row.External_Id_Field__c,
                Order__c: row.Order__c,
                Record_Limit__c: row.Record_Limit__c
            };
        } else if (action.name === 'delete') {
            this.removeTemplate(row);
        }
    }

    handleEditorChange(event) {
        const field = event.target.dataset.field;
        let value = event.detail.value;
        if ((field === 'Order__c' || field === 'Record_Limit__c') && value !== null && value !== undefined) {
            value = value === '' ? null : Number(value);
        }
        this.editing = { ...this.editing, [field]: value };
    }

    handleCancelEdit() {
        this.editing = undefined;
    }

    async handleSaveTemplate() {
        const inputs = [...this.template.querySelectorAll('.template-editor lightning-input, .template-editor lightning-textarea')];
        const valid = inputs.reduce((ok, el) => el.reportValidity() && ok, true);
        if (!valid) {
            return;
        }
        const record = { ...this.editing, sobjectType: 'CDO_Data_Template__c' };
        if (!record.Id) {
            record.Data_Set__c = this.selectedId;
        }
        this.working = true;
        try {
            await saveTemplate({ t: record });
            showToast(this, 'Template saved', `${record.Name || record.Object_API_Name__c} was saved.`, 'success');
            this.editing = undefined;
            await refreshAll(this.detailResult, this.dataSetsResult);
        } catch (e) {
            showError(this, 'Could not save the template', e);
        } finally {
            this.working = false;
        }
    }

    async removeTemplate(row) {
        const confirmed = await LightningConfirm.open({
            message: `Delete the template "${row.Name}" and its relationships?`,
            label: 'Delete template',
            theme: 'warning'
        });
        if (!confirmed) {
            return;
        }
        this.working = true;
        try {
            await deleteTemplate({ templateId: row.Id });
            showToast(this, 'Template deleted', `${row.Name} was deleted.`, 'success');
            await refreshAll(this.detailResult, this.dataSetsResult);
        } catch (e) {
            showError(this, 'Could not delete the template', e);
        } finally {
            this.working = false;
        }
    }

    async handleDeploy() {
        const confirmed = await LightningConfirm.open({
            message: `Deploy the records of ${this.dataSet.Name} from ${this.sourceEnv} to ${this.targetEnv}? Records are upserted in ${this.targetEnv}.`,
            label: 'Deploy data',
            theme: 'warning'
        });
        if (!confirmed) {
            return;
        }
        this.working = true;
        try {
            const message = await deployDataSet({ dataSetId: this.selectedId, sourceEnv: this.sourceEnv, targetEnv: this.targetEnv });
            showToast(this, 'Data deploy started', message, 'success');
            await refreshAll(this.detailResult, this.dataSetsResult);
        } catch (e) {
            showError(this, 'Could not deploy the data set', e);
        } finally {
            this.working = false;
        }
    }
}
