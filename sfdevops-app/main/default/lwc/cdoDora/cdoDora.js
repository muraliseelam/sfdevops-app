import { LightningElement, wire } from 'lwc';
import getProjects from '@salesforce/apex/PipelineController.getProjects';
import getMetrics from '@salesforce/apex/DoraController.getMetrics';
import { errorMessage, formatDate, formatHours, formatPercent, refreshAll, showError } from 'c/cdoUtils';

const WINDOW_OPTIONS = [
    { label: 'Last 30 days', value: '30' },
    { label: 'Last 60 days', value: '60' },
    { label: 'Last 90 days', value: '90' },
    { label: 'Last 180 days', value: '180' },
    { label: 'Last 365 days', value: '365' }
];

const LEVEL_CLASS = {
    Elite: 'slds-badge slds-theme_success',
    High: 'slds-badge slds-theme_info',
    Medium: 'slds-badge slds-theme_warning',
    Low: 'slds-badge slds-theme_error'
};

// Chart geometry (SVG user units; the SVG scales to its container).
const WIDTH = 640;
const HEIGHT = 220;
const MARGIN = { top: 12, right: 8, bottom: 28, left: 40 };
const PLOT_W = WIDTH - MARGIN.left - MARGIN.right;
const PLOT_H = HEIGHT - MARGIN.top - MARGIN.bottom;
const GAP = 2; // surface gap between stacked segments
const RADIUS = 4; // rounded data end

function niceCeil(value) {
    if (!value || value <= 0) {
        return 1;
    }
    const exp = Math.pow(10, Math.floor(Math.log10(value)));
    const f = value / exp;
    const nice = f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10;
    return nice * exp;
}

/** A bar path with rounded top corners only, anchored to the baseline. */
function barPath(x, y, w, h, rounded) {
    if (h <= 0) {
        return '';
    }
    const r = rounded ? Math.min(RADIUS, h, w / 2) : 0;
    const bottom = y + h;
    if (!r) {
        return `M${x},${bottom}V${y}H${x + w}V${bottom}Z`;
    }
    return `M${x},${bottom}V${y + r}Q${x},${y} ${x + r},${y}H${x + w - r}Q${x + w},${y} ${x + w},${y + r}V${bottom}Z`;
}

function round(n) {
    return Math.round(n * 10) / 10;
}

/**
 * DORA delivery metrics: four tiles plus weekly bar charts drawn with plain SVG.
 */
export default class CdoDora extends LightningElement {
    projectId = null;
    days = '30';
    projects = [];
    metrics;
    error;
    isLoading = true;
    showTables = false;
    metricsResult;

    windowOptions = WINDOW_OPTIONS;

    @wire(getProjects)
    wiredProjects({ data }) {
        if (data) {
            this.projects = data;
        }
    }

    @wire(getMetrics, { projectId: '$projectId', days: '$daysNumber' })
    wiredMetrics(result) {
        this.metricsResult = result;
        if (result.data) {
            this.metrics = result.data;
            this.error = undefined;
            this.isLoading = false;
        } else if (result.error) {
            this.error = errorMessage(result.error);
            this.isLoading = false;
        }
    }

    // -----------------------------------------------------------------------------------------
    // Filters
    // -----------------------------------------------------------------------------------------

    get daysNumber() {
        return Number(this.days);
    }

    get projectOptions() {
        return [{ label: 'All projects', value: '' }, ...this.projects.map((p) => ({ label: p.Name, value: p.Id }))];
    }

    get projectValue() {
        return this.projectId || '';
    }

    get showProjectPicker() {
        return this.projects.length > 1;
    }

    handleProjectChange(event) {
        this.projectId = event.detail.value || null;
    }

    handleWindowChange(event) {
        this.days = event.detail.value;
    }

    handleRefresh() {
        refreshAll(this.metricsResult).catch((e) => showError(this, 'Could not refresh the metrics', e));
    }

    handleToggleTables() {
        this.showTables = !this.showTables;
    }

    // -----------------------------------------------------------------------------------------
    // Tiles
    // -----------------------------------------------------------------------------------------

    get hasMetrics() {
        return !!this.metrics;
    }

    get hasDeployments() {
        return this.metrics && this.metrics.totalDeployments > 0;
    }

    get periodLabel() {
        if (!this.metrics) {
            return '';
        }
        return `${formatDate(this.metrics.since)} to ${formatDate(this.metrics.untilTime)}`;
    }

    get tiles() {
        const m = this.metrics;
        if (!m) {
            return [];
        }
        const tile = (key, title, value, unit, level, detail, help) => ({
            key,
            title,
            value: value === '' || value === null || value === undefined ? '—' : value,
            unit,
            level,
            levelClass: LEVEL_CLASS[level] || 'slds-badge',
            hasLevel: !!level,
            detail,
            help,
            headingId: `tile-${key}`
        });
        return [
            tile(
                'frequency',
                'Deployment frequency',
                m.successfulDeployments ? String(round(m.deploymentFrequencyPerWeek)) : '0',
                'per week',
                m.deploymentFrequencyLevel,
                `${m.successfulDeployments} successful production deploy${m.successfulDeployments === 1 ? '' : 's'} in ${m.days} days`,
                'Successful production Deploy and QuickDeploy runs per week.'
            ),
            tile(
                'leadTime',
                'Lead time for changes',
                formatHours(m.leadTimeHours),
                'median',
                m.leadTimeLevel,
                m.leadTimeSampleSize
                    ? `Across ${m.leadTimeSampleSize} work item${m.leadTimeSampleSize === 1 ? '' : 's'}`
                    : 'No work item reached production with a recorded commit',
                'First commit on a work item to its first successful production deploy.'
            ),
            tile(
                'failureRate',
                'Change failure rate',
                m.totalDeployments ? formatPercent(m.changeFailureRate) : '',
                '',
                m.changeFailureLevel,
                m.totalDeployments ? `${m.failedDeployments} of ${m.totalDeployments} production deploys failed` : 'No production deploys yet',
                'Failed production deploys divided by all production deploys.'
            ),
            tile(
                'mttr',
                'Time to restore',
                formatHours(m.mttrHours),
                'mean',
                m.mttrLevel,
                m.mttrSampleSize
                    ? `Across ${m.mttrSampleSize} recover${m.mttrSampleSize === 1 ? 'y' : 'ies'}`
                    : m.failedDeployments
                    ? 'No recovery after the failures yet'
                    : 'No failures to recover from',
                'From a failed production deploy to the next successful one.'
            )
        ];
    }

    // -----------------------------------------------------------------------------------------
    // Charts
    // -----------------------------------------------------------------------------------------

    get weeks() {
        return this.metrics ? this.metrics.weeks || [] : [];
    }

    get viewBox() {
        return `0 0 ${WIDTH} ${HEIGHT}`;
    }

    get baselineY() {
        return MARGIN.top + PLOT_H;
    }

    get plotLeft() {
        return MARGIN.left;
    }

    get plotRight() {
        return WIDTH - MARGIN.right;
    }

    band(n) {
        return PLOT_W / Math.max(n, 1);
    }

    xLabels(weeks) {
        const n = weeks.length;
        const every = Math.max(1, Math.ceil(n / 8));
        const band = this.band(n);
        return weeks
            .map((w, i) => ({ key: `x-${i}`, x: round(MARGIN.left + i * band + band / 2), y: HEIGHT - 8, text: w.label, show: i % every === 0 }))
            .filter((l) => l.show);
    }

    yTicks(yMax, integerOnly, format) {
        return [0, yMax / 2, yMax]
            .filter((v) => !integerOnly || Number.isInteger(v))
            .map((v) => {
                const y = round(MARGIN.top + PLOT_H - (v / yMax) * PLOT_H);
                return { key: `y-${v}`, y, labelY: y + 3, x1: MARGIN.left, x2: WIDTH - MARGIN.right, labelX: MARGIN.left - 6, text: format(v) };
            });
    }

    /** Stacked weekly bars: successful deploys at the base, failures on top. */
    get deployChart() {
        const weeks = this.weeks;
        const n = weeks.length;
        const maxTotal = Math.max(0, ...weeks.map((w) => w.deployments + w.failures));
        const yMax = niceCeil(maxTotal);
        const band = this.band(n);
        const barW = Math.min(28, band * 0.6);
        const bars = weeks.map((w, i) => {
            const x = round(MARGIN.left + i * band + (band - barW) / 2);
            const successH = (w.deployments / yMax) * PLOT_H;
            const failH = (w.failures / yMax) * PLOT_H;
            const successY = MARGIN.top + PLOT_H - successH;
            const failGap = successH > 0 && failH > 0 ? GAP : 0;
            const failY = successY - failGap - failH;
            const total = w.deployments + w.failures;
            return {
                key: `d-${i}`,
                successPath: barPath(x, round(successY), round(barW), round(successH), w.failures === 0),
                failurePath: barPath(x, round(failY), round(barW), round(failH), true),
                hitX: round(MARGIN.left + i * band),
                hitY: MARGIN.top,
                hitW: round(band),
                hitH: PLOT_H,
                tooltip: `Week of ${w.label}: ${w.deployments} successful, ${w.failures} failed`,
                valueLabel: total > 0 && n <= 13 ? String(total) : '',
                valueX: round(x + barW / 2),
                valueY: round((w.failures ? failY : successY) - 4)
            };
        });
        return {
            bars,
            ticks: this.yTicks(yMax, true, (v) => String(v)),
            labels: this.xLabels(weeks),
            hasData: maxTotal > 0
        };
    }

    /** Weekly median lead time (hours) for work items first reaching production that week. */
    get leadChart() {
        const weeks = this.weeks;
        const n = weeks.length;
        const values = weeks.map((w) => (w.leadTimeHours === null || w.leadTimeHours === undefined ? null : Number(w.leadTimeHours)));
        const maxValue = Math.max(0, ...values.filter((v) => v !== null));
        const yMax = niceCeil(maxValue);
        const band = this.band(n);
        const barW = Math.min(28, band * 0.6);
        const bars = weeks.map((w, i) => {
            const v = values[i];
            const x = round(MARGIN.left + i * band + (band - barW) / 2);
            const h = v === null ? 0 : (v / yMax) * PLOT_H;
            const y = MARGIN.top + PLOT_H - h;
            return {
                key: `l-${i}`,
                path: barPath(x, round(y), round(barW), round(h), true),
                hitX: round(MARGIN.left + i * band),
                hitY: MARGIN.top,
                hitW: round(band),
                hitH: PLOT_H,
                tooltip: v === null ? `Week of ${w.label}: no work item reached production` : `Week of ${w.label}: median lead time ${formatHours(v)}`,
                valueLabel: v !== null && n <= 13 ? formatHours(v) : '',
                valueX: round(x + barW / 2),
                valueY: round(y - 4)
            };
        });
        return {
            bars,
            ticks: this.yTicks(yMax, false, (v) => (v === 0 ? '0' : formatHours(v))),
            labels: this.xLabels(weeks),
            hasData: values.some((v) => v !== null)
        };
    }

    get deployChartSummary() {
        const m = this.metrics;
        return m ? `Production deployments per week: ${m.successfulDeployments} successful and ${m.failedDeployments} failed in ${m.days} days.` : '';
    }

    get leadChartSummary() {
        const m = this.metrics;
        return m && m.leadTimeHours !== null && m.leadTimeHours !== undefined
            ? `Median lead time per week. Overall median ${formatHours(m.leadTimeHours)}.`
            : 'Median lead time per week. No data yet.';
    }

    get tableRows() {
        return this.weeks.map((w, i) => ({
            key: `t-${i}`,
            label: w.label,
            deployments: w.deployments,
            failures: w.failures,
            leadTime: w.leadTimeHours === null || w.leadTimeHours === undefined ? '—' : formatHours(w.leadTimeHours)
        }));
    }

    get tablesExpanded() {
        return this.showTables ? 'true' : 'false';
    }

    get tableToggleLabel() {
        return this.showTables ? 'Hide data table' : 'Show data table';
    }

    get tableClass() {
        return this.showTables ? 'slds-table slds-table_cell-buffer slds-table_bordered slds-m-top_small' : 'slds-assistive-text';
    }
}
