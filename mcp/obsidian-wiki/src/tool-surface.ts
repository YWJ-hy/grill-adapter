export type McpToolProfile =
  | 'default'
  | 'research'
  | 'capture'
  | 'maintenance-audit'
  | 'maintenance-consolidation'
  | 'outbox'
  | 'legacy';

export const DEFAULT_MCP_TOOL_PROFILE: McpToolProfile = 'default';

const profileTools: Record<McpToolProfile, readonly string[]> = {
  // The default server preserves the normal workflow surface but keeps legacy
  // proposal/apply operations behind the explicit migration profile.
  default: [
    'obsidian_wiki_status',
    'obsidian_wiki_sources',
    'obsidian_wiki_search',
    'obsidian_wiki_catalog',
    'obsidian_wiki_maintenance_summary',
    'obsidian_wiki_consolidation_candidates',
    'obsidian_wiki_stage_capture_plan',
    'obsidian_wiki_capture_draft_view',
    'obsidian_wiki_outbox_review',
    'obsidian_wiki_outbox_correct',
    'obsidian_wiki_read_note',
    'obsidian_wiki_read_notes',
    'obsidian_wiki_read_notes_by_wiki_ids',
    'obsidian_wiki_graph_neighbors',
  ],
  research: [
    'obsidian_wiki_status',
    'obsidian_wiki_sources',
    'obsidian_wiki_search',
    'obsidian_wiki_catalog',
    'obsidian_wiki_read_note',
    'obsidian_wiki_read_notes',
    'obsidian_wiki_read_notes_by_wiki_ids',
    'obsidian_wiki_graph_neighbors',
  ],
  capture: [
    'obsidian_wiki_status',
    'obsidian_wiki_sources',
    'obsidian_wiki_search',
    'obsidian_wiki_catalog',
    'obsidian_wiki_read_notes_by_wiki_ids',
    'obsidian_wiki_consolidation_candidates',
    'obsidian_wiki_capture_draft_view',
    'obsidian_wiki_stage_capture_plan',
  ],
  'maintenance-audit': [
    'obsidian_wiki_status',
    'obsidian_wiki_sources',
    'obsidian_wiki_maintenance_summary',
    'obsidian_wiki_read_notes_by_wiki_ids',
  ],
  'maintenance-consolidation': [
    'obsidian_wiki_status',
    'obsidian_wiki_sources',
    'obsidian_wiki_consolidation_candidates',
  ],
  outbox: [
    'obsidian_wiki_status',
    'obsidian_wiki_sources',
    'obsidian_wiki_capture_draft_view',
    'obsidian_wiki_outbox_review',
    'obsidian_wiki_outbox_correct',
  ],
  legacy: [
    'obsidian_wiki_status',
    'obsidian_wiki_sources',
    'obsidian_wiki_propose_note_change',
    'obsidian_wiki_apply_note_change',
  ],
};

export function resolveMcpToolProfile(env: NodeJS.ProcessEnv = process.env): McpToolProfile {
  const value = env.OBSIDIAN_WIKI_MCP_PROFILE;
  if (value === undefined || value === '') return DEFAULT_MCP_TOOL_PROFILE;
  if (value === 'migration') return 'legacy';
  if (Object.prototype.hasOwnProperty.call(profileTools, value)) return value as McpToolProfile;
  throw new Error(`Unknown Obsidian Wiki MCP profile: ${value}`);
}

export function profileHasTool(profile: McpToolProfile, toolName: string): boolean {
  return profileTools[profile].includes(toolName);
}
