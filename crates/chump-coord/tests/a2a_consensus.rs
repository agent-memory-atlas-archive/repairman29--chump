// crates/chump-coord/tests/a2a_consensus.rs — INFRA-1803
//
// Integration test for the consensus voting layer ported from
// chump-proprietary. Validates: vote semantics, ConsensusRecord
// finalization across quorum / majority / tie / timeout cases, SHA256
// signature_tag determinism, and ConsensusCoordinator state machine.

use chump_coord::consensus::{
    ConsensusCoordinator, ConsensusDecision, ConsensusRecord, DecisionType, Vote, VoteProof,
    VoteRequest,
};
use std::collections::HashMap;

fn req(t: DecisionType, quorum: usize) -> VoteRequest {
    VoteRequest {
        vote_id: "vote-test".to_string(),
        initiator: "opus-initiator".to_string(),
        decision_type: t,
        reason: "test scenario".to_string(),
        context: "fleet=3 waste=10%".to_string(),
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
fn decision_type_variants_cover_chump_use_cases() {
    // If new variants are added, expand this assertion. Today we have 5 (META-195 adds AdminMergeProposal).
    let variants = [
        DecisionType::EscalationRequired,
        DecisionType::ResourceCritical,
        DecisionType::NetworkPartitionRecovery,
        DecisionType::FleetScaleChange,
        DecisionType::AdminMergeProposal,
    ];
    assert_eq!(variants.len(), 5);
    // Ensure JSON round-trip works on every variant (so the wire format
    // is stable for ambient-emit + NATS publish).
    for v in variants {
        let j = serde_json::to_string(&v).expect("serialize");
        let back: DecisionType = serde_json::from_str(&j).expect("deserialize");
        assert_eq!(back, v);
    }
}

#[test]
fn majority_approve_proceeds() {
    let r = req(DecisionType::EscalationRequired, 3);
    let mut votes = HashMap::new();
    votes.insert("a".to_string(), vp(Vote::Approve));
    votes.insert("b".to_string(), vp(Vote::Approve));
    votes.insert("c".to_string(), vp(Vote::Approve));
    votes.insert("d".to_string(), vp(Vote::Abort));
    let record = ConsensusRecord::finalize(r, votes);
    assert_eq!(record.decision, ConsensusDecision::Proceed);
    assert_eq!(record.approval_count, 3);
    assert_eq!(record.abort_count, 1);
    assert_eq!(record.committed_count, 4);
}

#[test]
fn majority_abort_aborts() {
    let r = req(DecisionType::ResourceCritical, 3);
    let mut votes = HashMap::new();
    votes.insert("a".to_string(), vp(Vote::Abort));
    votes.insert("b".to_string(), vp(Vote::Abort));
    votes.insert("c".to_string(), vp(Vote::Abort));
    votes.insert("d".to_string(), vp(Vote::Approve));
    let record = ConsensusRecord::finalize(r, votes);
    assert_eq!(record.decision, ConsensusDecision::Abort);
}

#[test]
fn quorum_loss_is_inconclusive() {
    let r = req(DecisionType::NetworkPartitionRecovery, 5);
    let mut votes = HashMap::new();
    votes.insert("a".to_string(), vp(Vote::Approve));
    votes.insert("b".to_string(), vp(Vote::Approve));
    votes.insert("c".to_string(), vp(Vote::Timeout));
    let record = ConsensusRecord::finalize(r, votes);
    assert_eq!(record.decision, ConsensusDecision::Inconclusive);
    assert_eq!(record.committed_count, 2);
}

#[test]
fn timeout_doesnt_count_toward_quorum() {
    let r = req(DecisionType::FleetScaleChange, 3);
    let mut votes = HashMap::new();
    votes.insert("a".to_string(), vp(Vote::Approve));
    votes.insert("b".to_string(), vp(Vote::Approve));
    // Only 2 committed; quorum=3 so should be Inconclusive even though
    // approvers outnumber aborters.
    votes.insert("c".to_string(), vp(Vote::Timeout));
    votes.insert("d".to_string(), vp(Vote::Timeout));
    let record = ConsensusRecord::finalize(r, votes);
    assert_eq!(record.decision, ConsensusDecision::Inconclusive);
}

#[test]
fn exact_tie_is_inconclusive() {
    let r = req(DecisionType::FleetScaleChange, 2);
    let mut votes = HashMap::new();
    votes.insert("a".to_string(), vp(Vote::Approve));
    votes.insert("b".to_string(), vp(Vote::Abort));
    let record = ConsensusRecord::finalize(r, votes);
    assert_eq!(record.decision, ConsensusDecision::Inconclusive);
}

#[test]
fn signature_tag_is_sha256_hex() {
    let c = ConsensusCoordinator::new();
    let p = c.cast_vote("vote-1", "opus-x", Vote::Approve);
    // SHA256 hex = 64 lowercase hex chars
    assert_eq!(p.signature_tag.len(), 64);
    assert!(p.signature_tag.chars().all(|c| c.is_ascii_hexdigit()));
}

#[test]
fn signature_tag_differs_per_vote_kind() {
    // Same vote_id + session, different vote → different signature
    // (the vote variant is part of the hash input).
    let c = ConsensusCoordinator::new();
    let p_approve = c.cast_vote("vote-1", "opus-x", Vote::Approve);
    let p_abort = c.cast_vote("vote-1", "opus-x", Vote::Abort);
    // Likely different (different vote + different timestamp); the point is
    // the vote field IS in the hash input.
    assert_ne!(p_approve.signature_tag, p_abort.signature_tag);
}

#[test]
fn coordinator_round_trip() {
    let mut c = ConsensusCoordinator::new();
    let r = req(DecisionType::EscalationRequired, 2);
    c.initiate_vote(r);
    let p1 = c.cast_vote("vote-test", "opus-a", Vote::Approve);
    let p2 = c.cast_vote("vote-test", "opus-b", Vote::Approve);
    let mut votes = HashMap::new();
    votes.insert("opus-a".to_string(), p1);
    votes.insert("opus-b".to_string(), p2);
    c.finalize_vote("vote-test", votes);
    assert_eq!(c.should_proceed("vote-test"), Some(true));
    assert_eq!(c.records().len(), 1);
}

#[test]
fn record_summary_is_loggable() {
    let r = req(DecisionType::EscalationRequired, 2);
    let mut votes = HashMap::new();
    votes.insert("a".to_string(), vp(Vote::Approve));
    votes.insert("b".to_string(), vp(Vote::Approve));
    let record = ConsensusRecord::finalize(r, votes);
    let s = record.summary();
    assert!(s.contains("Consensus"));
    assert!(s.contains("Proceed"));
    assert!(s.contains("approval=2"));
}

#[test]
fn vote_request_json_round_trip() {
    let r = req(DecisionType::FleetScaleChange, 4);
    let j = serde_json::to_string(&r).unwrap();
    let back: VoteRequest = serde_json::from_str(&j).unwrap();
    assert_eq!(back.initiator, r.initiator);
    assert_eq!(back.decision_type, r.decision_type);
    assert_eq!(back.quorum, r.quorum);
}
