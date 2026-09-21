// THIS IS A NOVA SECTOR UI FILE
import { useState } from 'react';
import {
  Box,
  Button,
  Icon,
  Input,
  LabeledList,
  NoticeBox,
  ProgressBar,
  Section,
  Stack,
  Table,
  Tabs,
  Tooltip,
} from 'tgui-core/components';
import type { BooleanLike } from 'tgui-core/react';
import { createSearch } from 'tgui-core/string';

import { useBackend } from '../backend';
import { Window } from '../layouts';
import { MarkdownRenderer } from './MarkdownViewer';

import aboutContent from './DogmosKennel/docs/about.md';
import creditsContent from './DogmosKennel/docs/credits.md';
import glossaryContent from './DogmosKennel/docs/glossary.md';

type DogmosCosts = {
  turfs: number;
  groups: number;
  highpressure: number;
  equalize: number;
  superconductivity: number;
  // APHELION EDIT ADDITION START - DOGMOS
  pipenets: number;
  // APHELION EDIT ADDITION END
  post_process: number;
};

// APHELION EDIT ADDITION START - DOGMOS
type ProcessMetrics = {
  dreamdaemon: {
    private_bytes: number;
    virtual_bytes: number;
    working_set_bytes: number;
    available: BooleanLike;
  };
  dogmosd: {
    rss_bytes: number;
    cpu_total_milliseconds: number;
    available: BooleanLike;
  };
};
// APHELION EDIT ADDITION END

type FireGroupEntry = {
  time: string;
  jump_to: string | null;
  area: string;
  peak_size: number;
};

type HighCostZoneEntry = {
  time: string;
  jump_to: string | null;
  area: string;
  reaction: string;
  cost_ms: number;
};

type ExplosionEntry = {
  time: string;
  jump_to: string | null;
  area: string;
  devastation_range: number;
  heavy_impact_range: number;
  light_impact_range: number;
  cause: string;
  index: number;
};

type ReactionOfInterestEntry = {
  time: string;
  jump_to: string | null;
  area: string;
  reaction: string;
  amount: number;
};

type BreachEntry = {
  time: string;
  jump_to: string | null;
  area: string;
  moles_lost: number;
};

type StructureOfInterestEntry = {
  ref: string;
  name: string;
  area: string;
  reason: string;
  pinned_at: string;
  expires: number | null;
};

type MachineBrowseEntry = {
  ref: string;
  name: string;
  area: string;
};

type Data = {
  active_size: number;
  hotspots_size: number;
  conducting_size: number;
  low_pressure_turfs: number;
  high_pressure_turfs: number;
  group_turfs_processed: number;
  equalize_processed: number;
  space_boundary_size: number;
  heat_telemetry: {
    graph_nodes: number;
    edge_attempts: number;
    edges_applied: number;
    lock_contention: number;
    registration_changes: number;
    callback_enqueue_failures: number;
  };
  dogmos_costs: DogmosCosts;
  // APHELION EDIT ADDITION START - DOGMOS
  process_metrics: ProcessMetrics;
  // APHELION EDIT ADDITION END
  frozen: BooleanLike;
  show_all: BooleanLike;
  realistic_space_radiation: BooleanLike;
  equalize_enabled: BooleanLike;
  fire_count: number;
  showing_user: BooleanLike;
  kennel_slow_mode: BooleanLike;
  flamethrower_directional_spread: BooleanLike;
  event_counts: {
    fire_groups: number;
    high_cost_zones: number;
    explosions: number;
    reactions_of_interest: number;
    breaches: number;
  };
  recent_fire_groups: FireGroupEntry[];
  recent_high_cost_zones: HighCostZoneEntry[];
  recent_explosions: ExplosionEntry[];
  recent_reactions_of_interest: ReactionOfInterestEntry[];
  recent_breaches: BreachEntry[];
  structures_of_interest: StructureOfInterestEntry[];
  atmos_machinery_browse?: MachineBrowseEntry[];
  atmos_machinery_browse_page?: number;
  atmos_machinery_browse_pages?: number;
  atmos_machinery_browse_total?: number;
  atmos_machinery_browse_search?: string;
  kennel_browse_page_size: number;
  kennel_browse_search_max_length: number;
  kennel_fire_group_notable_size: number;
  kennel_reaction_magnitude_threshold: number;
  kennel_machine_cost_ms_threshold: number;
  kennel_profile_reactions: BooleanLike;
  kennel_high_cost_ms_threshold: number;
};

enum TABS {
  Overview = 'Overview',
  'Fire Groups' = 'Fire Groups',
  Profiling = 'Profiling',
  'High-Cost Zones' = 'High-Cost Zones',
  Explosions = 'Explosions',
  Breaches = 'Breaches',
  'Structures/Machines' = 'Structures/Machines',
  About = 'About',
  Glossary = 'Glossary',
  Credits = 'Credits',
}

type EventCountKey = keyof Data['event_counts'];

const TAB_EVENT_COUNT_KEYS: Partial<Record<TABS, EventCountKey>> = {
  [TABS['Fire Groups']]: 'fire_groups',
  [TABS['High-Cost Zones']]: 'high_cost_zones',
  [TABS.Explosions]: 'explosions',
  [TABS.Profiling]: 'reactions_of_interest',
  [TABS.Breaches]: 'breaches',
};

// Cost bands match the MC panel, scaled to Dogmos' per-stage millisecond range.
const STAGE_COST_RANGES = {
  good: [0, 4.99],
  average: [5, 9.99],
  bad: [10, Infinity],
} as const;
const STAGE_COST_MAX = 20;

type StageCostRowProps = {
  label: string;
  cost: number;
  active: boolean;
  inactiveTooltip?: string;
};

/// Displays one Dogmos stage cost with its activity state and severity band.
const StageCostRow = (props: StageCostRowProps) => {
  const { label, cost, active, inactiveTooltip } = props;
  // APHELION EDIT ADDITION START - DOGMOS
  const validCost = Number.isFinite(cost) && cost >= 0;
  const displayCost = validCost ? cost : 0;
  const tooltip = !validCost
    ? 'Invalid timing sample. Negative and non-finite values are instrumentation errors, not work completed in reverse.'
    : !active
      ? inactiveTooltip
      : undefined;
  // APHELION EDIT ADDITION END
  const color = !validCost ? 'bad' : !active ? 'grey' : cost >= 10 ? 'bad' : cost >= 5 ? 'average' : 'good';
  return (
    <Table.Row>
      <Table.Cell collapsing align="center">
        {tooltip ? (
          <Tooltip content={tooltip}>
            <Icon name="paw" color={color} />
          </Tooltip>
        ) : (
          <Icon name="paw" color={color} />
        )}
      </Table.Cell>
      <Table.Cell>
        <ProgressBar
          value={displayCost}
          maxValue={STAGE_COST_MAX}
          ranges={STAGE_COST_RANGES}
          color={validCost ? undefined : 'bad'}
        >
          {label} {validCost ? `${cost.toFixed(2)}ms` : 'invalid sample'}
        </ProgressBar>
      </Table.Cell>
    </Table.Row>
  );
};

// APHELION EDIT ADDITION START - DOGMOS
const formatBinaryBytes = (bytes: number) => {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  let value = bytes;
  let unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  return `${value.toFixed(unitIndex ? 2 : 0)} ${units[unitIndex]}`;
};

const ProcessMetricsPanel = () => {
  const { data } = useBackend<Data>();
  const { dreamdaemon, dogmosd } = data.process_metrics;
  return (
    <Section title="Process Snapshots (operational only)">
      <Stack>
        <Stack.Item grow basis="50%">
          <Section title="DreamDaemon (32-bit host)" fill>
            {!dreamdaemon.available ? (
              <NoticeBox>Unavailable</NoticeBox>
            ) : (
              <LabeledList>
                <LabeledList.Item label="Private bytes">
                  {formatBinaryBytes(dreamdaemon.private_bytes)}
                </LabeledList.Item>
                <LabeledList.Item label="Virtual bytes">
                  {formatBinaryBytes(dreamdaemon.virtual_bytes)}
                </LabeledList.Item>
                <LabeledList.Item label="Working-set bytes">
                  {formatBinaryBytes(dreamdaemon.working_set_bytes)}
                </LabeledList.Item>
              </LabeledList>
            )}
          </Section>
        </Stack.Item>
        <Stack.Item grow basis="50%">
          <Section title="dogmosd (64-bit service)" fill>
            {!dogmosd.available ? (
              <NoticeBox>Unavailable</NoticeBox>
            ) : (
              <LabeledList>
                <LabeledList.Item label="Resident-set bytes">
                  {formatBinaryBytes(dogmosd.rss_bytes)}
                </LabeledList.Item>
                <LabeledList.Item label="Cumulative CPU">
                  {dogmosd.cpu_total_milliseconds.toLocaleString()} ms
                </LabeledList.Item>
              </LabeledList>
            )}
          </Section>
        </Stack.Item>
      </Stack>
    </Section>
  );
};
// APHELION EDIT ADDITION END

const KennelControls = () => {
  const { act, data } = useBackend<Data>();
  return (
    <Section
      title="Kennel Controls"
      buttons={
        <>
          <Button
            icon={data.frozen ? 'play' : 'pause'}
            color={data.frozen ? 'bad' : 'good'}
            onClick={() => act('toggle-freeze')}
          >
            {data.frozen ? 'Frozen' : 'Running'}
          </Button>
          <Button.Checkbox
            icon="eye"
            checked={data.showing_user}
            onClick={() => act('toggle_user_display')}
            tooltip="Turns on Dogmos' map overlays for you specifically: red breach tiles, orange high-cost zones, purple reaction events, cyan leashed structures."
          >
            Debug Overlays
          </Button.Checkbox>
          <Button.Checkbox
            icon="gauge-high"
            checked={data.kennel_slow_mode}
            onClick={() => act('toggle_kennel_slow_mode')}
            tooltip="ON (default): gates only the large machinery browse and throttles refresh cadence. All bounded event histories remain available. OFF: refreshes the machinery browse every cycle."
          >
            Slow Mode
          </Button.Checkbox>
        </>
      }
    />
  );
};

const OverviewPanel = (props) => {
  const { act, data } = useBackend<Data>();
  const costs = data.dogmos_costs || ({} as DogmosCosts);
  const equalizeActive = !!data.equalize_enabled;
  return (
    <>
      <Section title="Kennel Overview">
        <Stack fill>
          <Stack.Item grow>
            <LabeledList>
              <LabeledList.Item label="Fire Count">
                {data.fire_count}
              </LabeledList.Item>
              <LabeledList.Item label="Active Turfs">
                {data.active_size}
              </LabeledList.Item>
              <LabeledList.Item label="Hotspots">
                {data.hotspots_size}
              </LabeledList.Item>
              <LabeledList.Item label="Superconductors">
                {data.conducting_size}
              </LabeledList.Item>
              <LabeledList.Item label="Low / High Pressure Turfs">
                {data.low_pressure_turfs} / {data.high_pressure_turfs}
              </LabeledList.Item>
              <LabeledList.Item label="Group / Equalize Components">
                {data.group_turfs_processed} / {data.equalize_processed}
              </LabeledList.Item>
            </LabeledList>
          </Stack.Item>
          <Stack.Item grow>
            <LabeledList>
              <LabeledList.Item label="Space Boundary Nodes">
                {data.space_boundary_size}
              </LabeledList.Item>
              <LabeledList.Item label="Heat Graph Nodes">
                {data.heat_telemetry.graph_nodes}
              </LabeledList.Item>
              <LabeledList.Item label="Heat Edges (attempted / applied)">
                {data.heat_telemetry.edge_attempts} /{' '}
                {data.heat_telemetry.edges_applied}
              </LabeledList.Item>
              <LabeledList.Item label="Heat Lock Contention">
                {data.heat_telemetry.lock_contention}
              </LabeledList.Item>
              <LabeledList.Item label="Heat Registration Changes">
                {data.heat_telemetry.registration_changes}
              </LabeledList.Item>
              <LabeledList.Item label="Callback Enqueue Failures">
                {data.heat_telemetry.callback_enqueue_failures}
              </LabeledList.Item>
            </LabeledList>
          </Stack.Item>
        </Stack>
      </Section>
      {/* APHELION EDIT ADDITION START - DOGMOS */}
      <ProcessMetricsPanel />
      {/* APHELION EDIT ADDITION END */}
      <Section title="Atmospherics Stage Costs (smoothed wall time)">
        <Table>
          <StageCostRow label="Active Turfs / FDM" cost={costs.turfs ?? 0} active />
          <StageCostRow
            label="Excited Groups"
            cost={costs.groups ?? 0}
            active
          />
          <StageCostRow
            label="Pressure Equalization"
            cost={costs.highpressure ?? 0}
            active={equalizeActive}
            inactiveTooltip="Katmos Pressure Equalizer is off (below)"
          />
          <StageCostRow
            label="Superconductivity"
            cost={costs.superconductivity ?? 0}
            active
          />
          {/* APHELION EDIT ADDITION START - DOGMOS */}
          <StageCostRow label="Pipenets" cost={costs.pipenets ?? 0} active />
          {/* APHELION EDIT ADDITION END */}
        </Table>
      </Section>
      {!!data.kennel_slow_mode && (
        <NoticeBox>
          Slow mode is on - the machinery browse is gated and refresh cadence
          is reduced. All bounded event histories remain available.
        </NoticeBox>
      )}
      <Section title="Configuration">
        <Stack fill wrap>
          <Stack.Item grow basis="45%">
            <LabeledList>
              <LabeledList.Item label="Realistic Space Radiation">
                <Button.Checkbox
                  checked={data.realistic_space_radiation}
                  onClick={() => act('toggle_realistic_space_radiation')}
                  tooltip="ON: real Stefan-Boltzmann blackbody radiation. Cooling is intentionally weak near room temperature, so an exposed room will not instantly freeze. OFF: legacy fake vacuum sink for rapid, visible cooling. This changes heat loss only, not breach pressure or airflow."
                />
              </LabeledList.Item>
              <LabeledList.Item label="Katmos Pressure Equalizer">
                <Button.Checkbox
                  checked={data.equalize_enabled}
                  onClick={() => act('toggle_equalize_enabled')}
                  tooltip="Whether Dogmos' katmos pressure equalizer (and hull-breach handling) runs as part of the gas FDM pass."
                />
              </LabeledList.Item>
              <LabeledList.Item label="Flamethrower Directional Spread">
                <Button.Checkbox
                  checked={data.flamethrower_directional_spread}
                  onClick={() => act('toggle_flamethrower_directional_spread')}
                  tooltip="ON: keep the initial flamethrower hotspot below LINDA's bypass threshold so its radiated heat stays with the projected flame. OFF: preserve the legacy large hotspot behavior."
                />
              </LabeledList.Item>
            </LabeledList>
          </Stack.Item>
          <Stack.Item grow basis="45%">
            <LabeledList>
              <LabeledList.Item label="Fire Group Notable Size">
                <Input
                  width="4em"
                  value={`${data.kennel_fire_group_notable_size}`}
                  onChange={(value) =>
                    act('kennel_set_threshold', {
                      threshold: 'fire_group_notable_size',
                      value,
                    })
                  }
                />
              </LabeledList.Item>
              <LabeledList.Item label="Reaction Event Threshold">
                <Input
                  width="4em"
                  value={`${data.kennel_reaction_magnitude_threshold}`}
                  onChange={(value) =>
                    act('kennel_set_threshold', {
                      threshold: 'reaction_magnitude_threshold',
                      value,
                    })
                  }
                />
              </LabeledList.Item>
              <LabeledList.Item label="Machine Auto-Pin Threshold (ms)">
                <Input
                  width="4em"
                  value={`${data.kennel_machine_cost_ms_threshold}`}
                  onChange={(value) =>
                    act('kennel_set_threshold', {
                      threshold: 'machine_cost_ms_threshold',
                      value,
                    })
                  }
                />
              </LabeledList.Item>
              <LabeledList.Item label="High-Cost Reaction Threshold (ms)">
                <Input
                  width="4em"
                  value={`${data.kennel_high_cost_ms_threshold}`}
                  onChange={(value) =>
                    act('kennel_set_threshold', {
                      threshold: 'high_cost_ms_threshold',
                      value,
                    })
                  }
                />
              </LabeledList.Item>
            </LabeledList>
          </Stack.Item>
        </Stack>
      </Section>
    </>
  );
};

type Column<T> = {
  label: string;
  render: (entry: T) => React.ReactNode;
  collapsing?: boolean;
};

/** Shared searchable table for the recent Dogmos event histories. */
function EventHistoryTable<T extends { jump_to?: string | null }>(props: {
  entries: T[];
  columns: Column<T>[];
  searchKeys: (entry: T) => string;
  emptyText: string;
}) {
  const { act } = useBackend<Data>();
  const { entries, columns, searchKeys, emptyText } = props;
  const [searchText, setSearchText] = useState('');
  const filtered = searchText
    ? entries.filter(createSearch(searchText, searchKeys))
    : entries;
  const hasTargets = filtered.some((entry) => !!entry.jump_to);
  return (
    <>
      <Input
        placeholder="Search..."
        value={searchText}
        onChange={(value) => setSearchText(value)}
        fluid
        mb={1}
      />
      {!filtered.length && <NoticeBox>{emptyText}</NoticeBox>}
      {!!filtered.length && (
        <Table>
          <Table.Row header>
            {columns.map((col) => (
              <Table.Cell key={col.label} collapsing={col.collapsing}>
                {col.label}
              </Table.Cell>
            ))}
            {hasTargets && (
              <Table.Cell collapsing>Track</Table.Cell>
            )}
          </Table.Row>
          {filtered.map((entry, i) => (
            <tr key={i}>
              {columns.map((col) => (
                <td key={col.label}>{col.render(entry)}</td>
              ))}
              {hasTargets && (
                <td>
                  {!!entry.jump_to && (
                    <Button
                      icon="paw"
                      tooltip="Track scent"
                      onClick={() =>
                        act('move-to-target', { spot: entry.jump_to })
                      }
                    />
                  )}
                </td>
              )}
            </tr>
          ))}
        </Table>
      )}
    </>
  );
}

const FireGroupsPanel = (props) => {
  const { data } = useBackend<Data>();
  return (
    <Section
      title={`Recent Fire Groups (peak size >= ${data.kennel_fire_group_notable_size})`}
    >
      <EventHistoryTable
        entries={data.recent_fire_groups}
        searchKeys={(entry) => entry.area}
        emptyText="No notable fire groups recorded yet."
        columns={[
          { label: 'Time', render: (e) => e.time, collapsing: true },
          { label: 'Area', render: (e) => e.area },
          { label: 'Peak Size', render: (e) => e.peak_size, collapsing: true },
        ]}
      />
    </Section>
  );
};

const HighCostZonesPanel = (props) => {
  const { data } = useBackend<Data>();
  return (
    <Section
      title={`Recent High-Cost Reactions (single call >= ${data.kennel_high_cost_ms_threshold}ms)`}
    >
      {!data.kennel_profile_reactions && (
        <NoticeBox>
          Reaction profiling is off in the Profiling tab - this list stays empty
          until it's enabled. It has a real, opt-in Rust-side cost per
          reaction call, so it defaults off.
        </NoticeBox>
      )}
      {!!data.kennel_profile_reactions && !data.recent_high_cost_zones.length && (
        <NoticeBox>
          Profiling is on - no reactions have crossed the threshold yet.
        </NoticeBox>
      )}
      <EventHistoryTable
        entries={data.recent_high_cost_zones}
        searchKeys={(entry) => `${entry.area} ${entry.reaction}`}
        emptyText=""
        columns={[
          { label: 'Time', render: (e) => e.time, collapsing: true },
          { label: 'Area', render: (e) => e.area },
          { label: 'Reaction', render: (e) => e.reaction },
          { label: 'Cost', render: (e) => `${e.cost_ms}ms`, collapsing: true },
        ]}
      />
    </Section>
  );
};

const ExplosionsPanel = (props) => {
  const { data } = useBackend<Data>();
  return (
    <Section title="Recent Explosions">
      <EventHistoryTable
        entries={data.recent_explosions}
        searchKeys={(entry) => `${entry.area} ${entry.cause}`}
        emptyText="No explosions recorded yet."
        columns={[
          { label: 'Time', render: (e) => e.time, collapsing: true },
          { label: 'Area', render: (e) => e.area },
          { label: 'Cause', render: (e) => e.cause },
          {
            label: 'Range (D/H/L)',
            render: (e) =>
              `${e.devastation_range}/${e.heavy_impact_range}/${e.light_impact_range}`,
            collapsing: true,
          },
        ]}
      />
    </Section>
  );
};

const ProfilingPanel = (props) => {
  const { act, data } = useBackend<Data>();
  return (
    <>
      <Section
        title="Reaction profiler"
        buttons={
          <Button.Checkbox
            icon="stopwatch"
            checked={data.kennel_profile_reactions}
            onClick={() => act('toggle_kennel_profile_reactions')}
            tooltip="OFF (default): no per-reaction timer. ON: measures each Rust reaction call and records calls at or above the configured threshold."
          >
            Profile Reactions
          </Button.Checkbox>
        }
      >
        <Box mb={1}>
          Profiling is Dogmos' scent trail for reaction cost. When enabled, the
          Rust reaction dispatcher measures each reaction call, including calls
          that finish quickly. Only calls at or above the configured high-cost
          threshold are copied into High-Cost Zones, keeping the stored history
          bounded.
        </Box>
        <Box mb={1}>
          The Reaction Events table answers a different question: which reaction
          amounts changed enough to be operationally interesting. It is an event
          history, not a timing measurement, and remains available when profiling
          is off. Use the amount threshold to reduce noise in that history; use
          the profiling threshold to find expensive individual calls.
        </Box>
        <Box>
          Profiling adds real work to every reaction call, so leave it off during
          ordinary station operation. Turn it on for a bounded investigation,
          inspect the recorded areas and reactions, then turn it off again.
        </Box>
      </Section>
      <Section
        title={`Recent Reaction Events (amount >= ${data.kennel_reaction_magnitude_threshold})`}
      >
        <EventHistoryTable
          entries={data.recent_reactions_of_interest}
          searchKeys={(entry) => `${entry.area} ${entry.reaction}`}
          emptyText="No notable reactions recorded yet."
          columns={[
            { label: 'Time', render: (e) => e.time, collapsing: true },
            { label: 'Area', render: (e) => e.area },
            { label: 'Reaction', render: (e) => e.reaction },
            { label: 'Amount', render: (e) => e.amount, collapsing: true },
          ]}
        />
      </Section>
    </>
  );
};

const DocumentationPanel = (props: { title: string; content: string }) => (
  <Section title={props.title}>
    <MarkdownRenderer content={props.content} />
  </Section>
);

const BreachesPanel = (props) => {
  const { data } = useBackend<Data>();
  return (
    <Section title="Recent Breaches">
      <EventHistoryTable
        entries={data.recent_breaches}
        searchKeys={(entry) => entry.area}
        emptyText="No breaches recorded yet."
        columns={[
          { label: 'Time', render: (e) => e.time, collapsing: true },
          { label: 'Area', render: (e) => e.area },
          {
            label: 'Moles Lost',
            render: (e) => e.moles_lost,
            collapsing: true,
          },
        ]}
      />
    </Section>
  );
};

const StructuresPanel = (props) => {
  const { act, data } = useBackend<Data>();
  const [pinnedSearch, setPinnedSearch] = useState('');
  const pinned = pinnedSearch
    ? data.structures_of_interest.filter(
        createSearch(pinnedSearch, (e) => `${e.name} ${e.area} ${e.reason}`),
      )
    : data.structures_of_interest;
  const browse = data.atmos_machinery_browse || [];
  const browsePage = data.atmos_machinery_browse_page || 1;
  const browsePages = data.atmos_machinery_browse_pages || 1;
  const browseTotal = data.atmos_machinery_browse_total || 0;
  const browseSearch = data.atmos_machinery_browse_search || '';
  return (
    <>
      <Section title="Leashed / Flagged Structures &amp; Machines">
        <Input
          placeholder="Search leashed..."
          value={pinnedSearch}
          onChange={(value) => setPinnedSearch(value)}
          fluid
          mb={1}
        />
        {!pinned.length && (
          <NoticeBox>
            The kennel's empty - explosion causes, breach-adjacent machinery,
            and high per-cycle-cost machines auto-leash here, or leash one
            manually below.
          </NoticeBox>
        )}
        {!!pinned.length && (
          <Table>
            <Table.Row header>
              <Table.Cell>Name</Table.Cell>
              <Table.Cell>Area</Table.Cell>
              <Table.Cell>Reason</Table.Cell>
              <Table.Cell collapsing>Pinned At</Table.Cell>
              <Table.Cell collapsing />
            </Table.Row>
            {pinned.map((entry) => (
              <tr key={entry.ref}>
                <td>{entry.name}</td>
                <td>{entry.area}</td>
                <td>{entry.reason}</td>
                <td>{entry.pinned_at}</td>
                <td>
                  <Button
                    icon="crosshairs"
                    onClick={() =>
                      act('move-to-target', { spot: entry.ref })
                    }
                  />
                  <Button
                    icon="times"
                    color="bad"
                    tooltip="Unleash"
                    onClick={() =>
                      act('kennel_unpin', { ref: entry.ref })
                    }
                  />
                </td>
              </tr>
            ))}
          </Table>
        )}
      </Section>
      <Section title="Leash a Machine">
        {!data.atmos_machinery_browse && (
          <NoticeBox>
            Turn off Kennel Slow Mode in Kennel Controls to browse and manually
            leash any registered atmos machine/canister - this list can be
            large, so it's not sent while slow mode is on.
          </NoticeBox>
        )}
        {!!data.atmos_machinery_browse && (
          <>
            <Input
              placeholder="Search machinery..."
              value={browseSearch}
              maxLength={data.kennel_browse_search_max_length}
              onChange={(value) =>
                act('kennel_set_browse_search', { search: value })
              }
              fluid
              mb={1}
            />
            <Table>
              {browse.map((entry) => (
                <tr key={entry.ref}>
                  <td>{entry.name}</td>
                  <td>{entry.area}</td>
                  <td>
                    <Button
                      icon="paw"
                      content="Leash"
                      onClick={() => act('kennel_pin', { ref: entry.ref })}
                    />
                  </td>
                </tr>
              ))}
            </Table>
            <Stack align="center" mt={1}>
              <Stack.Item>
                <Button
                  icon="chevron-left"
                  disabled={browsePage <= 1}
                  onClick={() =>
                    act('kennel_set_browse_page', { page: browsePage - 1 })
                  }
                >
                  Previous
                </Button>
              </Stack.Item>
              <Stack.Item grow textAlign="center" color="label">
                Page {browsePage} of {browsePages}; {browseTotal} matching
                machines; at most {data.kennel_browse_page_size} rows per page
              </Stack.Item>
              <Stack.Item>
                <Button
                  icon="chevron-right"
                  disabled={browsePage >= browsePages}
                  onClick={() =>
                    act('kennel_set_browse_page', { page: browsePage + 1 })
                  }
                >
                  Next
                </Button>
              </Stack.Item>
            </Stack>
          </>
        )}
      </Section>
    </>
  );
};

export const DogmosKennel = (props) => {
  const { data } = useBackend<Data>();
  const tabs = Object.keys(TABS) as TABS[];
  const [currentTab, setCurrentTab] = useState<TABS>(tabs[0]);

  let componentShown;
  switch (currentTab) {
    case TABS['Fire Groups']:
      componentShown = <FireGroupsPanel />;
      break;
    case TABS['High-Cost Zones']:
      componentShown = <HighCostZonesPanel />;
      break;
    case TABS.Explosions:
      componentShown = <ExplosionsPanel />;
      break;
    case TABS.Profiling:
      componentShown = <ProfilingPanel />;
      break;
    case TABS['Structures/Machines']:
      componentShown = <StructuresPanel />;
      break;
    case TABS.Breaches:
      componentShown = <BreachesPanel />;
      break;
    case TABS.About:
      componentShown = <DocumentationPanel title="About Dogmos" content={aboutContent} />;
      break;
    case TABS.Glossary:
      componentShown = <DocumentationPanel title="Dogmos Glossary" content={glossaryContent} />;
      break;
    case TABS.Credits:
      componentShown = <DocumentationPanel title="Dogmos Credits" content={creditsContent} />;
      break;
    default:
      componentShown = <OverviewPanel />;
  }

  return (
    <Window title="🐾 Dogmos Kennel" width={900} height={680}>
      <Window.Content scrollable>
        <KennelControls />
        <Tabs>
          {tabs.map((tab) => {
            const eventCountKey = TAB_EVENT_COUNT_KEYS[tab];
            const eventCount = eventCountKey
              ? data.event_counts[eventCountKey]
              : 0;
            return (
              <Tabs.Tab
                key={tab}
                selected={currentTab === tab}
                onClick={() => setCurrentTab(tab)}
              >
                {tab}
                {!!eventCount && ` (${eventCount})`}
              </Tabs.Tab>
            );
          })}
        </Tabs>
        {componentShown}
      </Window.Content>
    </Window>
  );
};
