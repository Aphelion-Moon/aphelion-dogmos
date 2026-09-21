import { sortBy } from 'es-toolkit';
import { map } from 'es-toolkit/compat';
import { Box, Button, Flex, Section, Table } from 'tgui-core/components';

import { useBackend } from '../backend';
import { Window } from '../layouts';

export const AtmosControlPanel = (props) => {
  const { act, data } = useBackend();
  const groups = sortBy(
    map(data.excited_groups, (group, i) => ({
      ...group,
      // Generate a unique id
      id: group.area + i,
    })),
    [(group) => group.id],
  );
  return (
    <Window title="SSAir Control Panel" width={900} height={560}>
      <Section m={1}>
        <Flex justify="space-between" align="baseline">
          <Flex.Item>
            <Button
              onClick={() => act('toggle-freeze')}
              color={data.frozen === 1 ? 'good' : 'bad'}
            >
              {data.frozen === 1 ? 'Freeze Subsystem' : 'Unfreeze Subsystem'}
            </Button>
          </Flex.Item>
          <Flex.Item>Fire Cnt: {data.fire_count}</Flex.Item>
          <Flex.Item>Active Turfs: {data.active_size}</Flex.Item>
          <Flex.Item>Excited Groups: {data.excited_size}</Flex.Item>
          <Flex.Item>Hotspots: {data.hotspots_size}</Flex.Item>
          <Flex.Item>Superconductors: {data.conducting_size}</Flex.Item>
          <Flex.Item>
            <Button.Checkbox
              checked={data.showing_user}
              onClick={() => act('toggle_user_display')}
            >
              Personal View
            </Button.Checkbox>
          </Flex.Item>
          <Flex.Item>
            <Button.Checkbox
              checked={data.show_all}
              onClick={() => act('toggle_show_all')}
            >
              Display all
            </Button.Checkbox>
          </Flex.Item>
          <Flex.Item>
            <Button.Checkbox
              checked={data.realistic_space_radiation}
              onClick={() => act('toggle_realistic_space_radiation')}
              tooltip="ON: real Stefan-Boltzmann blackbody radiation (physically correct, weak near room temperature). OFF: fake vacuum sink (not physical, fast and legible)."
            >
              Realistic Space Radiation
            </Button.Checkbox>
          </Flex.Item>
        </Flex>
      </Section>
      <Section m={1} title="Dogmos (Rust) live activity">
        <Flex justify="space-between" align="baseline" wrap>
          <Flex.Item>Low Pressure Turfs: {data.low_pressure_turfs}</Flex.Item>
          <Flex.Item>High Pressure Turfs: {data.high_pressure_turfs}</Flex.Item>
          <Flex.Item>Group Turfs Processed: {data.group_turfs_processed}</Flex.Item>
          <Flex.Item>Equalize Processed: {data.equalize_processed}</Flex.Item>
          <Flex.Item>Space Boundary Nodes: {data.space_boundary_size}</Flex.Item>
        </Flex>
        <Flex justify="space-between" align="baseline" wrap mt={1}>
          <Flex.Item>FDM: {data.dogmos_costs?.turfs}ms</Flex.Item>
          <Flex.Item>Groups: {data.dogmos_costs?.groups}ms</Flex.Item>
          <Flex.Item>High Pressure: {data.dogmos_costs?.highpressure}ms</Flex.Item>
          <Flex.Item>Equalize: {data.dogmos_costs?.equalize}ms</Flex.Item>
          <Flex.Item>
            Superconductivity: {data.dogmos_costs?.superconductivity}ms
          </Flex.Item>
          <Flex.Item>Post Process: {data.dogmos_costs?.post_process}ms</Flex.Item>
        </Flex>
      </Section>
      <Box fillPositionedParent top="115px">
        <Window.Content scrollable>
          <Section title="Excited Groups (roundstart snapshot only - Rust's per-cycle equalization doesn't keep these updated)">
            <Table>
              <Table.Row header>
                <Table.Cell>Area Name</Table.Cell>
                <Table.Cell collapsing>Breakdown</Table.Cell>
                <Table.Cell collapsing>Dismantle</Table.Cell>
                <Table.Cell collapsing>Turfs</Table.Cell>
                <Table.Cell collapsing>
                  {data.display_max === 1 && 'Max Share'}
                </Table.Cell>
                <Table.Cell collapsing>Display</Table.Cell>
              </Table.Row>
              {groups.map((group) => (
                <tr key={group.id}>
                  <td>
                    <Button
                      content={group.area}
                      onClick={() =>
                        act('move-to-target', {
                          spot: group.jump_to,
                        })
                      }
                    />
                  </td>
                  <td>{group.breakdown}</td>
                  <td>{group.dismantle}</td>
                  <td>{group.size}</td>
                  <td>{data.display_max === 1 && group.max_share}</td>
                  <td>
                    <Button.Checkbox
                      checked={group.should_show}
                      onClick={() =>
                        act('toggle_show_group', {
                          group: group.group,
                        })
                      }
                    />
                  </td>
                </tr>
              ))}
            </Table>
          </Section>
        </Window.Content>
      </Box>
    </Window>
  );
};
