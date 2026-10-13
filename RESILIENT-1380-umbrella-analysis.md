# RESILIENT-1380: Legacy Umbrella Data Model Investigation

## Acceptance Criteria Fulfillment

✅ **AC1**: A list of all gap IDs with notes containing "Decomposed into" is produced.
- Complete list of 320 parent gaps extracted from the gap database
- All parent gap IDs and titles documented
- Available in detailed report output

✅ **AC2**: The list correctly distinguishes gaps with at least one child not done versus fully completed children.
- 0 gaps with all children fully completed
- 320 gaps with at least one child not completed
- Child status breakdown provided for each parent gap

## Summary of Findings

### Decomposition Scale
- **Total parent gaps with "Decomposed into"**: 320
- **Fully completed** (all children closed): 0
- **Partially completed** (at least one child open/blocked): 320

### Child Gap Status Distribution (2,626 total children)
| Status | Count | Percentage |
|--------|-------|-----------|
| open | 2,331 | 88.8% |
| blocked | 121 | 4.6% |
| done | 69 | 2.6% |
| NOT_FOUND | 62 | 2.4% |
| superseded | 19 | 0.7% |
| already_satisfied | 11 | 0.4% |
| wontfix | 7 | 0.3% |
| closed | 5 | 0.2% |
| in-progress | 1 | 0.0% |

## Analysis Methodology

The investigation queried the `.chump/state.db` SQLite database for all gaps whose notes field contained "Decomposed into". For each parent gap, the analysis:

1. Extracted child gap IDs from the notes pattern: "Decomposed into N slices: GAP-1, GAP-2, ..."
2. Queried the database to determine each child's current status
3. Classified parents as "fully completed" only if ALL children have status = "closed"
4. Counted child gaps with NOT_FOUND status (referenced but missing from database)

## Key Insights

### No Fully Completed Umbrellas
The absence of any fully completed parent gaps (0/320) indicates:
- The decomposition model is still actively in use across the fleet
- Child gaps span a wide range of statuses with most still in open state
- The umbrella model has high granularity but incomplete tracking

### Data Integrity Issues
The 62 NOT_FOUND children (2.4%) suggest:
- Stale decompositions that reference deleted gaps
- Possible data synchronization issues
- Need for a migration to a more structured decomposition model

### Open-Heavy Distribution
The 88.8% open rate reflects active development:
- Large backlog of decomposed child gaps
- Distributed work across many priorities
- Opportunity to consolidate decomposition approach

## Migration Implications

### Legacy Model Characteristics
The current "Decomposed into" pattern embedded in gap notes is:
- **Fragile**: References can break if child gaps are deleted
- **Unstructured**: String-based format requires parsing
- **Non-queryable**: Cannot efficiently query parent-child relationships
- **Not atomic**: Parent-child relationship exists only in notes, not enforced by schema

### Recommended Next Steps
1. **Formal schema migration**: Replace note-based decomposition with database relationships
2. **Data integrity audit**: Validate and repair the 62 NOT_FOUND references
3. **Completion tracking**: Implement automatic parent completion when all children are closed
4. **Query optimization**: Enable efficient queries for decomposition tree traversal

## Data Source
- Database: `~/.chump/state.db`
- Query: All gaps where `notes LIKE '%Decomposed into%'`
- Query timestamp: 2026-10-13
- Total gaps analyzed: 320 parents, 2,626 children
