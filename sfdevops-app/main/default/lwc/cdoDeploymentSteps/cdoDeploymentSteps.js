import { LightningElement, api, wire } from 'lwc';
import LightningConfirm from 'lightning/confirm';
import getSteps from '@salesforce/apex/DeploymentStepController.getSteps';
import saveStep from '@salesforce/apex/DeploymentStepController.saveStep';
import completeStep from '@salesforce/apex/DeploymentStepController.completeStep';
import deleteStep from '@salesforce/apex/DeploymentStepController.deleteStep';
import reorder from '@salesforce/apex/DeploymentStepController.reorder';
import { errorMessage, formatDateTime, labelOf, refreshAll, showError, showToast, statusBadgeClass } from 'c/cdoUtils';

const PHASES = [
    { value: 'Pre', label: 'Pre-deployment', description: 'Before the deploy starts' },
    { value: 'Deploy', label: 'During deployment', description: 'Alongside the metadata deploy' },
    { value: 'Post', label: 'Post-deployment', description: 'After the deploy succeeds' }
];
const PHASE_OPTIONS = PHASES.map((p) => ({ label: p.label, value: p.value }));
const TYPE_OPTIONS = ['Manual', 'Apex', 'Data', 'Command'].map((t) => ({ label: t, value: t }));
const STATUS_OPTIONS = ['Pending', 'In_Progress', 'Skipped', 'Failed'].map((s) => ({ label: labelOf(s), value: s }));

/**
 * Manual deployment steps for a work item, grouped by phase: add, edit, complete, delete and
 * move up or down within a phase.
 */
export default class CdoDeploymentSteps extends LightningElement {
    @api recordId;

    steps = [];
    error;
    wiredResult;
    working = false;

    editing; // the step being edited, or a new draft
    phaseOptions = PHASE_OPTIONS;
    typeOptions = TYPE_OPTIONS;
    statusOptions = STATUS_OPTIONS;

    @wire(getSteps, { workItemId: '$recordId' })
    wiredSteps(result) {
        this.wiredResult = result;
        if (result.data) {
            this.steps = result.data;
            this.error = undefined;
        } else if (result.error) {
            this.error = errorMessage(result.error);
        }
    }

    // -----------------------------------------------------------------------------------------
    // View state
    // -----------------------------------------------------------------------------------------

    get hasRecord() {
        return !!this.recordId;
    }

    get phases() {
        return PHASES.map((phase) => {
            const inPhase = this.steps.filter((s) => (s.Phase__c || 'Pre') === phase.value);
            const done = inPhase.filter((s) => s.Status__c === 'Done').length;
            return {
                ...phase,
                headingId: `phase-${phase.value}`,
                isEmpty: inPhase.length === 0,
                progressLabel: inPhase.length ? `${done} of ${inPhase.length} done` : '',
                steps: inPhase.map((s, index) => ({
                    ...s,
                    position: index + 1,
                    isFirst: index === 0,
                    isLast: index === inPhase.length - 1,
                    isDone: s.Status__c === 'Done',
                    statusLabel: labelOf(s.Status__c),
                    statusClass: statusBadgeClass(s.Status__c),
                    completedLabel: s.Completed_On__c
                        ? `Done by ${s.Completed_By__r ? s.Completed_By__r.Name : 'someone'} on ${formatDateTime(s.Completed_On__c)}`
                        : '',
                    moveUpLabel: `Move ${s.Name} up`,
                    moveDownLabel: `Move ${s.Name} down`,
                    editLabel: `Edit ${s.Name}`,
                    completeLabel: `Mark ${s.Name} done`,
                    deleteLabel: `Delete ${s.Name}`,
                    moveUpDisabled: this.working || index === 0,
                    moveDownDisabled: this.working || index === inPhase.length - 1
                }))
            };
        });
    }

    get hasSteps() {
        return this.steps.length > 0;
    }

    get summary() {
        const done = this.steps.filter((s) => s.Status__c === 'Done').length;
        return this.steps.length ? `${done} of ${this.steps.length} steps done` : '';
    }

    get isEditing() {
        return !!this.editing;
    }

    get modalTitle() {
        return this.editing && this.editing.Id ? 'Edit step' : 'New step';
    }

    get showStatusPicker() {
        return this.editing && !!this.editing.Id && !this.editing.isDone;
    }

    // -----------------------------------------------------------------------------------------
    // Handlers
    // -----------------------------------------------------------------------------------------

    handleRefresh() {
        refreshAll(this.wiredResult).catch((e) => showError(this, 'Could not refresh the steps', e));
    }

    handleAdd(event) {
        const phase = (event.currentTarget && event.currentTarget.dataset.phase) || 'Pre';
        this.editing = { Name: '', Phase__c: phase, Type__c: 'Manual', Instructions__c: '', Status__c: 'Pending' };
    }

    handleEdit(event) {
        const step = this.steps.find((s) => s.Id === event.currentTarget.dataset.id);
        if (step) {
            this.editing = {
                Id: step.Id,
                Name: step.Name,
                Phase__c: step.Phase__c,
                Type__c: step.Type__c,
                Instructions__c: step.Instructions__c,
                Status__c: step.Status__c,
                Stage__c: step.Stage__c,
                Deployment__c: step.Deployment__c,
                isDone: step.Status__c === 'Done'
            };
        }
    }

    handleFieldChange(event) {
        const field = event.target.dataset.field;
        this.editing = { ...this.editing, [field]: event.detail.value };
    }

    handleCloseModal() {
        this.editing = undefined;
    }

    handleModalKeydown(event) {
        if (event.key === 'Escape') {
            this.handleCloseModal();
        }
    }

    async handleSave() {
        const inputs = [...this.template.querySelectorAll('.step-form lightning-input, .step-form lightning-textarea, .step-form lightning-combobox')];
        const valid = inputs.reduce((ok, el) => el.reportValidity() && ok, true);
        if (!valid) {
            return;
        }
        const { isDone, ...fields } = this.editing;
        const record = { ...fields, sobjectType: 'CDO_Deployment_Step__c' };
        if (isDone) {
            delete record.Status__c;
        }
        if (!record.Id) {
            record.Work_Item__c = this.recordId;
            delete record.Status__c;
        }
        this.working = true;
        try {
            await saveStep({ s: record });
            showToast(this, 'Step saved', `${record.Name || 'The step'} was saved.`, 'success');
            this.editing = undefined;
            await refreshAll(this.wiredResult);
        } catch (e) {
            showError(this, 'Could not save the step', e);
        } finally {
            this.working = false;
        }
    }

    async handleComplete(event) {
        const id = event.currentTarget.dataset.id;
        this.working = true;
        try {
            const step = await completeStep({ stepId: id });
            showToast(this, 'Step done', `${step.Name} is marked done.`, 'success');
            await refreshAll(this.wiredResult);
        } catch (e) {
            showError(this, 'Could not complete the step', e);
        } finally {
            this.working = false;
        }
    }

    async handleDelete(event) {
        const step = this.steps.find((s) => s.Id === event.currentTarget.dataset.id);
        if (!step) {
            return;
        }
        const confirmed = await LightningConfirm.open({
            message: `Delete the step "${step.Name}"?`,
            label: 'Delete step',
            theme: 'warning'
        });
        if (!confirmed) {
            return;
        }
        this.working = true;
        try {
            await deleteStep({ stepId: step.Id });
            showToast(this, 'Step deleted', `${step.Name} was deleted.`, 'success');
            await refreshAll(this.wiredResult);
        } catch (e) {
            showError(this, 'Could not delete the step', e);
        } finally {
            this.working = false;
        }
    }

    handleMoveUp(event) {
        this.move(event.currentTarget.dataset.id, -1);
    }

    handleMoveDown(event) {
        this.move(event.currentTarget.dataset.id, 1);
    }

    async move(stepId, delta) {
        const step = this.steps.find((s) => s.Id === stepId);
        if (!step) {
            return;
        }
        const phase = step.Phase__c || 'Pre';
        const ids = this.steps.filter((s) => (s.Phase__c || 'Pre') === phase).map((s) => s.Id);
        const from = ids.indexOf(stepId);
        const to = from + delta;
        if (to < 0 || to >= ids.length) {
            return;
        }
        [ids[from], ids[to]] = [ids[to], ids[from]];
        this.working = true;
        try {
            await reorder({ stepIds: ids });
            await refreshAll(this.wiredResult);
        } catch (e) {
            showError(this, 'Could not reorder the steps', e);
        } finally {
            this.working = false;
        }
    }
}
