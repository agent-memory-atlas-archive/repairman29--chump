// crates/chump-coord/src/consensus.rs — INFRA-1803
//
// Distributed consensus for fleet-level decisions among Opus sessions.
// Ported from chump-proprietary's crates/coord/src/consensus/mod.rs
// (MIT-licensed); adapted from multi-robot swarm to LLM-agent fleet:
//   - robot_id → session_id in operator-facing fields
//   - DecisionType::ThreatAssessment dropped (robot-specific)
//   - DecisionType::FleetScaleChange added (chump-specific: should we
//     scale up/down based on waste-rate + ship-rate per INFRA-518?)
//
// When individual Opus sessions encounter scenarios requiring collective
// agreement (unknown gap classification, fleet scale-up/down threshold,
// scratchpad CAS contention recovery, network partition fallback), they
// initiate a vote across active sessions. Decisions land by majority with
// SHA256 vote-proof audit trail.
//
// This is the META-061 Layer 4 foundation. The pattern is mature from
// the robotics domain; LLM-agent applications include scale decisions,
// gap-priority bumps that need fleet-wide agreement, and recovery from
// split-brain after a network partition.
//
// INFRA-2162 (META-125/C3) ambient event registration note: this crate
// does not yet write to ambient.jsonl (ConsensusCoordinator is an in-memory
// primitive; no caller wires its decisions to the ambient stream). The
// following kinds from the EVENT_REGISTRY.yaml consensus-pipeline block
// are registered with status: planned and anchored here as the future
// home once that wiring lands:
//   - consensus_routed_to_curator — C4 curator-subscriber daemon, not built
//   - consensus_resolved          — ConsensusCoordinator::finalize_vote,
//                                    below, does not emit yet (see fn doc)
//   - roadmap_rerank_proposed     — C10 roadmap-pivot subcommand, not built
//   - roadmap_rerank_applied      — C10 roadmap-pivot subcommand, not built
// scanner-anchor: "kind":"consensus_routed_to_curator"
// scanner-anchor: "kind":"roadmap_rerank_proposed"
// scanner-anchor: "kind":"roadmap_rerank_applied"

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;

/// Default mode for the consensus admin-merge gate (META-195 flips INFRA-2274
/// from `"shadow"` to `"enforce"`).
pub const DEFAULT_CONSENSUS_MERGE_GATE_MODE: &str = "enforce";

/// Returns the default consensus admin-merge gate mode (`"enforce"`, META-195).
pub fn default_consensus_merge_gate_mode() -> &'static str {
    DEFAULT_CONSENSUS_MERGE_GATE_MODE
}

/// Types of decisions the fleet must make collectively.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum DecisionType {
    /// Encountered ambiguous case (e.g. unknown gap priority); seek
    /// fleet-wide authorization before proceeding.
    #[serde(alias = "escalation_required", alias = "escalation-required")]
    EscalationRequired,
    /// Critical resource depletion (token budget, GraphQL bucket); abort
    /// or push forward?
    #[serde(alias = "resource_critical", alias = "resource-critical")]
    ResourceCritical,
    /// Network partition detected; should affected sessions fall back to
    /// local autonomy?
    #[serde(
        alias = "network_partition_recovery",
        alias = "network-partition-recovery"
    )]
    NetworkPartitionRecovery,
    /// Should the fleet scale up/down? Triggered when INFRA-518 gates
    /// suggest a change but operator hasn't explicitly approved.
    #[serde(alias = "fleet_scale_change", alias = "fleet-scale-change")]
    FleetScaleChange,
    /// META-195: Proposal to execute a `gh pr merge --admin` override by
    /// multi-agent consensus (`decision_type=admin_merge_proposal`).
    #[serde(alias = "admin_merge_proposal", alias = "admin-merge-proposal")]
    AdminMergeProposal,
}

impl DecisionType {
    /// Canonical snake_case identifier used by CLI flags and shell bridges.
    pub fn as_str(&self) -> &'static str {
        match self {
            DecisionType::EscalationRequired => "escalation_required",
            DecisionType::ResourceCritical => "resource_critical",
            DecisionType::NetworkPartitionRecovery => "network_partition_recovery",
            DecisionType::FleetScaleChange => "fleet_scale_change",
            DecisionType::AdminMergeProposal => "admin_merge_proposal",
        }
    }
}

impl std::fmt::Display for DecisionType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

impl std::str::FromStr for DecisionType {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim() {
            "EscalationRequired" | "escalation_required" | "escalation-required" => {
                Ok(DecisionType::EscalationRequired)
            }
            "ResourceCritical" | "resource_critical" | "resource-critical" => {
                Ok(DecisionType::ResourceCritical)
            }
            "NetworkPartitionRecovery"
            | "network_partition_recovery"
            | "network-partition-recovery" => Ok(DecisionType::NetworkPartitionRecovery),
            "FleetScaleChange" | "fleet_scale_change" | "fleet-scale-change" => {
                Ok(DecisionType::FleetScaleChange)
            }
            "AdminMergeProposal" | "admin_merge_proposal" | "admin-merge-proposal" => {
                Ok(DecisionType::AdminMergeProposal)
            }
            other => Err(format!("unknown DecisionType: {other}")),
        }
    }
}

/// A single session's vote on a fleet decision.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Vote {
    /// Proceed with the action.
    Approve,
    /// Abort the action.
    Abort,
    /// Timeout: session did not respond within the vote window.
    Timeout,
}

impl Vote {
    /// True if this is a real commitment (not a missed-response Timeout).
    pub fn is_committed(&self) -> bool {
        matches!(self, Vote::Approve | Vote::Abort)
    }
}

/// Outcome of a fleet-wide consensus.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ConsensusDecision {
    /// Majority approved: proceed.
    Proceed,
    /// Majority aborted: action stopped.
    Abort,
    /// Split vote, quorum loss, or exact tie.
    Inconclusive,
}

/// A vote initiated by some session and broadcast to peers.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct VoteRequest {
    /// Unique identifier (UUID or session+timestamp).
    pub vote_id: String,
    /// Which session initiated the vote.
    pub initiator: String,
    /// What type of decision is being voted on.
    pub decision_type: DecisionType,
    /// Human-readable reason (logged in ambient + audit).
    pub reason: String,
    /// Additional structured context (e.g. waste-rate snapshot,
    /// graphql-bucket-remaining, current pillar focus).
    pub context: String,
    /// Quorum required to decide (e.g. 3 of 5 active Opus sessions).
    pub quorum: usize,
    /// Timeout in seconds before non-responders are marked Timeout.
    pub timeout_secs: u32,
}

/// Cryptographic proof of a single vote.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct VoteProof {
    /// SHA256 hex of (vote_id + session_id + vote + timestamp).
    pub signature_tag: String,
    /// When the vote was cast (RFC3339).
    pub timestamp: String,
    /// The actual vote.
    pub vote: Vote,
}

/// Result of a finalized vote round, suitable for audit replay.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConsensusRecord {
    pub request: VoteRequest,
    /// All votes received, keyed by session_id.
    pub votes: HashMap<String, VoteProof>,
    pub decision: ConsensusDecision,
    pub committed_count: usize,
    pub approval_count: usize,
    pub abort_count: usize,
}

impl ConsensusRecord {
    /// Compute the decision from a set of votes against the request's
    /// quorum.
    pub fn finalize(request: VoteRequest, votes: HashMap<String, VoteProof>) -> Self {
        let committed_count = votes.values().filter(|p| p.vote.is_committed()).count();
        let approval_count = votes.values().filter(|p| p.vote == Vote::Approve).count();
        let abort_count = votes.values().filter(|p| p.vote == Vote::Abort).count();

        let decision = if committed_count < request.quorum {
            ConsensusDecision::Inconclusive
        } else if approval_count > abort_count {
            ConsensusDecision::Proceed
        } else if abort_count > approval_count {
            ConsensusDecision::Abort
        } else {
            ConsensusDecision::Inconclusive
        };

        Self {
            request,
            votes,
            decision,
            committed_count,
            approval_count,
            abort_count,
        }
    }

    /// One-line audit summary suitable for ambient log emission.
    pub fn summary(&self) -> String {
        format!(
            "Consensus {} (type={:?}, approval={}/{}, abort={}/{}, decision={:?})",
            self.request.vote_id,
            self.request.decision_type,
            self.approval_count,
            self.committed_count,
            self.abort_count,
            self.committed_count,
            self.decision,
        )
    }
}

/// Stateful coordinator that tracks in-flight votes and finalized records.
pub struct ConsensusCoordinator {
    active_votes: HashMap<String, VoteRequest>,
    completed_records: Vec<ConsensusRecord>,
}

impl Default for ConsensusCoordinator {
    fn default() -> Self {
        Self::new()
    }
}

impl ConsensusCoordinator {
    pub fn new() -> Self {
        Self {
            active_votes: HashMap::new(),
            completed_records: Vec::new(),
        }
    }

    /// Open a new vote (call from the initiating session).
    pub fn initiate_vote(&mut self, request: VoteRequest) {
        self.active_votes.insert(request.vote_id.clone(), request);
    }

    /// Cast a session's vote and produce a SHA256-signed proof. The proof
    /// is the audit-replayable artifact; the consensus decision is reached
    /// when finalize_vote is called.
    pub fn cast_vote(&self, vote_id: &str, session_id: &str, vote: Vote) -> VoteProof {
        let timestamp = chrono::Utc::now().to_rfc3339();
        let tag_input = format!("{}{}{:?}{}", vote_id, session_id, vote, timestamp);
        let mut hasher = Sha256::new();
        hasher.update(tag_input.as_bytes());
        let result = hasher.finalize();
        // sha2 0.11 returns `Array<u8, ...>` which doesn't impl LowerHex
        // directly; format each byte manually. 32 bytes → 64 hex chars.
        let mut signature_tag = String::with_capacity(64);
        for byte in result.iter() {
            use std::fmt::Write as _;
            let _ = write!(signature_tag, "{:02x}", byte);
        }
        VoteProof {
            signature_tag,
            timestamp,
            vote,
        }
    }

    /// Finalize a vote against the collected proofs.
    // INFRA-2162: this is the "quorum reached and decision final" moment
    // scripts/ci/event-registry-reserved.txt's old `consensus_resolved`
    // entry pointed at — it does not yet write to ambient.jsonl (in-memory
    // only). `chump pe-suite status` already reads `kind=consensus_resolved`
    // for its convergence-rate metric; wiring a real emit here is the
    // follow-up that makes that metric non-zero outside demo fixtures.
    // scanner-anchor: "kind":"consensus_resolved"
    pub fn finalize_vote(&mut self, vote_id: &str, votes: HashMap<String, VoteProof>) {
        if let Some(request) = self.active_votes.remove(vote_id) {
            let record = ConsensusRecord::finalize(request, votes);
            self.completed_records.push(record);
        }
    }

    pub fn records(&self) -> Vec<ConsensusRecord> {
        self.completed_records.clone()
    }

    /// Quick should-proceed query for a completed vote.
    pub fn should_proceed(&self, vote_id: &str) -> Option<bool> {
        self.completed_records
            .iter()
            .find(|r| r.request.vote_id == vote_id)
            .and_then(|r| match r.decision {
                ConsensusDecision::Proceed => Some(true),
                ConsensusDecision::Abort => Some(false),
                ConsensusDecision::Inconclusive => None,
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_request(t: DecisionType, quorum: usize) -> VoteRequest {
        VoteRequest {
            vote_id: "vote-1".to_string(),
            initiator: "opus-1".to_string(),
            decision_type: t,
            reason: "test".to_string(),
            context: "test-context".to_string(),
            quorum,
            timeout_secs: 5,
        }
    }

    fn vp(vote: Vote) -> VoteProof {
        VoteProof {
            signature_tag: "sig".to_string(),
            timestamp: "2026-05-23T15:00:00Z".to_string(),
            vote,
        }
    }

    #[test]
    fn vote_committed_semantics() {
        assert!(Vote::Approve.is_committed());
        assert!(Vote::Abort.is_committed());
        assert!(!Vote::Timeout.is_committed());
    }

    #[test]
    fn majority_approve_proceeds() {
        let req = make_request(DecisionType::EscalationRequired, 3);
        let mut votes = HashMap::new();
        votes.insert("a".to_string(), vp(Vote::Approve));
        votes.insert("b".to_string(), vp(Vote::Approve));
        votes.insert("c".to_string(), vp(Vote::Approve));
        votes.insert("d".to_string(), vp(Vote::Abort));
        let r = ConsensusRecord::finalize(req, votes);
        assert_eq!(r.decision, ConsensusDecision::Proceed);
        assert_eq!(r.approval_count, 3);
        assert_eq!(r.abort_count, 1);
        assert_eq!(r.committed_count, 4);
    }

    #[test]
    fn quorum_loss_is_inconclusive() {
        let req = make_request(DecisionType::ResourceCritical, 5);
        let mut votes = HashMap::new();
        votes.insert("a".to_string(), vp(Vote::Approve));
        votes.insert("b".to_string(), vp(Vote::Approve));
        votes.insert("c".to_string(), vp(Vote::Timeout));
        let r = ConsensusRecord::finalize(req, votes);
        assert_eq!(r.decision, ConsensusDecision::Inconclusive);
        assert_eq!(r.committed_count, 2);
    }

    #[test]
    fn exact_tie_is_inconclusive() {
        let req = make_request(DecisionType::FleetScaleChange, 2);
        let mut votes = HashMap::new();
        votes.insert("a".to_string(), vp(Vote::Approve));
        votes.insert("b".to_string(), vp(Vote::Abort));
        let r = ConsensusRecord::finalize(req, votes);
        assert_eq!(r.decision, ConsensusDecision::Inconclusive);
    }

    #[test]
    fn vote_proof_deterministic_for_same_input() {
        let c = ConsensusCoordinator::new();
        // Two casts with same inputs produce same signature_tag IF
        // timestamps were identical. Timestamps come from chrono::Utc::now()
        // so we can't pin equality; instead just check the proof has the
        // right hex length (SHA256 hex = 64 chars).
        let p = c.cast_vote("v1", "session-x", Vote::Approve);
        assert_eq!(p.signature_tag.len(), 64);
        assert_eq!(p.vote, Vote::Approve);
    }

    #[test]
    fn coordinator_roundtrip() {
        let mut c = ConsensusCoordinator::new();
        let req = make_request(DecisionType::NetworkPartitionRecovery, 2);
        c.initiate_vote(req);
        let p1 = c.cast_vote("vote-1", "opus-a", Vote::Approve);
        let p2 = c.cast_vote("vote-1", "opus-b", Vote::Approve);
        let mut votes = HashMap::new();
        votes.insert("opus-a".to_string(), p1);
        votes.insert("opus-b".to_string(), p2);
        c.finalize_vote("vote-1", votes);
        assert_eq!(c.should_proceed("vote-1"), Some(true));
        assert_eq!(c.records().len(), 1);
    }

    #[test]
    fn meta_195_admin_merge_proposal_serde_and_from_str_roundtrip() {
        let dt = DecisionType::AdminMergeProposal;
        assert_eq!(dt.as_str(), "admin_merge_proposal");
        assert_eq!(
            "admin_merge_proposal".parse::<DecisionType>().unwrap(),
            DecisionType::AdminMergeProposal
        );
        assert_eq!(
            "admin-merge-proposal".parse::<DecisionType>().unwrap(),
            DecisionType::AdminMergeProposal
        );
        assert_eq!(
            "AdminMergeProposal".parse::<DecisionType>().unwrap(),
            DecisionType::AdminMergeProposal
        );
        let json = serde_json::to_string(&dt).unwrap();
        let back: DecisionType = serde_json::from_str(&json).unwrap();
        assert_eq!(back, DecisionType::AdminMergeProposal);
        let from_snake: DecisionType = serde_json::from_str("\"admin_merge_proposal\"").unwrap();
        assert_eq!(from_snake, DecisionType::AdminMergeProposal);
    }

    #[test]
    fn meta_195_admin_merge_proposal_consensus_reaches_approved_and_default_mode_is_enforce() {
        assert_eq!(default_consensus_merge_gate_mode(), "enforce");
        let mut c = ConsensusCoordinator::new();
        let req = VoteRequest {
            vote_id: "admin-merge-pr-4200".to_string(),
            initiator: "bot-merge".to_string(),
            decision_type: DecisionType::AdminMergeProposal,
            reason: "gh-api-5xx transient while checks green".to_string(),
            context: "pr=4200 gap=META-195".to_string(),
            quorum: 2,
            timeout_secs: 60,
        };
        c.initiate_vote(req);
        let p1 = c.cast_vote("admin-merge-pr-4200", "curator-a", Vote::Approve);
        let p2 = c.cast_vote("admin-merge-pr-4200", "curator-b", Vote::Approve);
        let mut votes = HashMap::new();
        votes.insert("curator-a".to_string(), p1);
        votes.insert("curator-b".to_string(), p2);
        c.finalize_vote("admin-merge-pr-4200", votes);
        assert_eq!(c.should_proceed("admin-merge-pr-4200"), Some(true));
        let rec = &c.records()[0];
        assert_eq!(rec.request.decision_type, DecisionType::AdminMergeProposal);
        assert_eq!(rec.decision, ConsensusDecision::Proceed);
        assert_eq!(rec.approval_count, 2);
    }
}
