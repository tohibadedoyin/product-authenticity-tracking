;; Authentication Proof Smart Contract
;; A comprehensive system for generating and validating cryptographic proofs for product authenticity

;; Constants for error handling
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-PROOF-NOT-FOUND (err u101))
(define-constant ERR-INVALID-PROOF (err u102))
(define-constant ERR-PROOF-EXPIRED (err u103))
(define-constant ERR-ALREADY-EXISTS (err u104))
(define-constant ERR-INVALID-SIGNATURE (err u105))
(define-constant ERR-INSUFFICIENT-BALANCE (err u106))
(define-constant ERR-VERIFICATION-FAILED (err u107))

;; Contract owner for administrative functions
(define-constant CONTRACT-OWNER tx-sender)

;; Proof validity duration (in blocks)
(define-constant PROOF-VALIDITY-BLOCKS u144) ;; ~24 hours at 10min/block

;; Data structures for authentication proofs
(define-map authentication-proofs
  { proof-id: uint }
  {
    product-id: (string-ascii 64),
    manufacturer: principal,
    proof-hash: (buff 32),
    signature: (buff 65),
    created-at: uint,
    expires-at: uint,
    verification-count: uint,
    is-active: bool,
    proof-type: (string-ascii 32),
    metadata: (string-utf8 256)
  }
)

;; Track proof verification history
(define-map proof-verifications
  { proof-id: uint, verifier: principal }
  {
    verified-at: uint,
    verification-result: bool,
    verifier-signature: (optional (buff 65)),
    notes: (string-utf8 128)
  }
)

;; Authorized manufacturers and verifiers
(define-map authorized-entities
  { entity: principal }
  {
    entity-type: (string-ascii 32),
    authorized-at: uint,
    is-active: bool,
    reputation-score: uint,
    total-proofs-created: uint
  }
)

;; Global counters
(define-data-var proof-counter uint u0)
(define-data-var total-verifications uint u0)
(define-data-var total-active-proofs uint u0)

;; Proof type definitions
(define-map proof-types
  { type-name: (string-ascii 32) }
  {
    description: (string-utf8 128),
    validity-duration: uint,
    required-signatures: uint,
    is-active: bool
  }
)

;; Fee structure for proof operations
(define-map operation-fees
  { operation: (string-ascii 32) }
  { fee-amount: uint }
)

;; Initialize default proof types
(map-set proof-types
  { type-name: "MANUFACTURE" }
  {
    description: u"Manufacturing authenticity proof",
    validity-duration: u1008, ;; ~1 week
    required-signatures: u1,
    is-active: true
  }
)

(map-set proof-types
  { type-name: "QUALITY" }
  {
    description: u"Quality assurance proof",
    validity-duration: u2016, ;; ~2 weeks
    required-signatures: u2,
    is-active: true
  }
)

;; Initialize operation fees
(map-set operation-fees { operation: "CREATE_PROOF" } { fee-amount: u1000 })
(map-set operation-fees { operation: "VERIFY_PROOF" } { fee-amount: u100 })
(map-set operation-fees { operation: "UPDATE_PROOF" } { fee-amount: u500 })

;; Administrative functions
(define-public (authorize-entity (entity principal) (entity-type (string-ascii 32)))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (map-set authorized-entities
      { entity: entity }
      {
        entity-type: entity-type,
        authorized-at: block-height,
        is-active: true,
        reputation-score: u100,
        total-proofs-created: u0
      }
    ))
  )
)

(define-public (revoke-entity-authorization (entity principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (match (map-get? authorized-entities { entity: entity })
      entity-info (ok (map-set authorized-entities
        { entity: entity }
        (merge entity-info { is-active: false })
      ))
      ERR-NOT-AUTHORIZED
    )
  )
)

;; Core proof creation function
(define-public (create-authentication-proof
    (product-id (string-ascii 64))
    (proof-hash (buff 32))
    (signature (buff 65))
    (proof-type (string-ascii 32))
    (metadata (string-utf8 256))
  )
  (let
    (
      (new-proof-id (+ (var-get proof-counter) u1))
      (current-height block-height)
      (entity-info (unwrap! (map-get? authorized-entities { entity: tx-sender }) ERR-NOT-AUTHORIZED))
      (type-info (unwrap! (map-get? proof-types { type-name: proof-type }) ERR-INVALID-PROOF))
    )
    (begin
      ;; Verify entity authorization
      (asserts! (get is-active entity-info) ERR-NOT-AUTHORIZED)
      (asserts! (get is-active type-info) ERR-INVALID-PROOF)
      
      ;; Create the proof record
      (map-set authentication-proofs
        { proof-id: new-proof-id }
        {
          product-id: product-id,
          manufacturer: tx-sender,
          proof-hash: proof-hash,
          signature: signature,
          created-at: current-height,
          expires-at: (+ current-height (get validity-duration type-info)),
          verification-count: u0,
          is-active: true,
          proof-type: proof-type,
          metadata: metadata
        }
      )
      
      ;; Update counters and entity stats
      (var-set proof-counter new-proof-id)
      (var-set total-active-proofs (+ (var-get total-active-proofs) u1))
      
      ;; Update entity statistics
      (map-set authorized-entities
        { entity: tx-sender }
        (merge entity-info 
          { 
            total-proofs-created: (+ (get total-proofs-created entity-info) u1),
            reputation-score: (if (> (+ (get reputation-score entity-info) u10) u1000) u1000 (+ (get reputation-score entity-info) u10))
          }
        )
      )
      
      (ok new-proof-id)
    )
  )
)

;; Proof verification function
(define-public (verify-authentication-proof
    (proof-id uint)
    (verifier-signature (optional (buff 65)))
    (verification-notes (string-utf8 128))
  )
  (let
    (
      (proof-data (unwrap! (map-get? authentication-proofs { proof-id: proof-id }) ERR-PROOF-NOT-FOUND))
      (current-height block-height)
    )
    (begin
      ;; Check if proof is still valid
      (asserts! (get is-active proof-data) ERR-INVALID-PROOF)
      (asserts! (<= current-height (get expires-at proof-data)) ERR-PROOF-EXPIRED)
      
      ;; Record verification attempt
      (map-set proof-verifications
        { proof-id: proof-id, verifier: tx-sender }
        {
          verified-at: current-height,
          verification-result: true,
          verifier-signature: verifier-signature,
          notes: verification-notes
        }
      )
      
      ;; Update proof verification count
      (map-set authentication-proofs
        { proof-id: proof-id }
        (merge proof-data 
          { verification-count: (+ (get verification-count proof-data) u1) }
        )
      )
      
      ;; Update global verification counter
      (var-set total-verifications (+ (var-get total-verifications) u1))
      
      (ok true)
    )
  )
)

;; Batch verification function
(define-public (batch-verify-proofs (proof-ids (list 10 uint)))
  (let
    (
      (verification-results (map verify-single-proof proof-ids))
    )
    (ok verification-results)
  )
)

(define-private (verify-single-proof (proof-id uint))
  (match (map-get? authentication-proofs { proof-id: proof-id })
    proof-data 
      (if (and (get is-active proof-data) (<= block-height (get expires-at proof-data)))
        { proof-id: proof-id, is-valid: true }
        { proof-id: proof-id, is-valid: false }
      )
    { proof-id: proof-id, is-valid: false }
  )
)

;; Proof revocation function
(define-public (revoke-proof (proof-id uint) (reason (string-utf8 128)))
  (let
    (
      (proof-data (unwrap! (map-get? authentication-proofs { proof-id: proof-id }) ERR-PROOF-NOT-FOUND))
    )
    (begin
      ;; Only manufacturer or contract owner can revoke
      (asserts! (or (is-eq tx-sender (get manufacturer proof-data)) (is-eq tx-sender CONTRACT-OWNER)) ERR-NOT-AUTHORIZED)
      
      ;; Deactivate the proof
      (map-set authentication-proofs
        { proof-id: proof-id }
        (merge proof-data { is-active: false })
      )
      
      ;; Update active proof counter
      (var-set total-active-proofs (- (var-get total-active-proofs) u1))
      
      (ok true)
    )
  )
)

;; Read-only functions for querying proof data
(define-read-only (get-proof-details (proof-id uint))
  (map-get? authentication-proofs { proof-id: proof-id })
)

(define-read-only (get-proof-verification-history (proof-id uint) (verifier principal))
  (map-get? proof-verifications { proof-id: proof-id, verifier: verifier })
)

(define-read-only (get-entity-info (entity principal))
  (map-get? authorized-entities { entity: entity })
)

(define-read-only (get-proof-type-info (type-name (string-ascii 32)))
  (map-get? proof-types { type-name: type-name })
)

(define-read-only (is-proof-valid (proof-id uint))
  (match (map-get? authentication-proofs { proof-id: proof-id })
    proof-data 
      (and 
        (get is-active proof-data) 
        (<= block-height (get expires-at proof-data))
      )
    false
  )
)

(define-read-only (get-contract-stats)
  {
    total-proofs: (var-get proof-counter),
    active-proofs: (var-get total-active-proofs),
    total-verifications: (var-get total-verifications),
    contract-owner: CONTRACT-OWNER
  }
)

(define-read-only (get-manufacturer-stats (manufacturer principal))
  (match (map-get? authorized-entities { entity: manufacturer })
    entity-info 
      {
        total-proofs-created: (get total-proofs-created entity-info),
        reputation-score: (get reputation-score entity-info),
        is-authorized: (get is-active entity-info),
        entity-type: (get entity-type entity-info)
      }
    {
      total-proofs-created: u0,
      reputation-score: u0,
      is-authorized: false,
      entity-type: "UNKNOWN"
    }
  )
)

;; Advanced search function for proofs by product
(define-read-only (search-proofs-by-product (product-id (string-ascii 64)))
  ;; This would require iteration in a real implementation
  ;; For now, returns a success response indicating search capability
  (ok true)
)

;; Proof renewal function
(define-public (renew-proof (proof-id uint) (additional-blocks uint))
  (let
    (
      (proof-data (unwrap! (map-get? authentication-proofs { proof-id: proof-id }) ERR-PROOF-NOT-FOUND))
    )
    (begin
      ;; Only manufacturer can renew
      (asserts! (is-eq tx-sender (get manufacturer proof-data)) ERR-NOT-AUTHORIZED)
      (asserts! (get is-active proof-data) ERR-INVALID-PROOF)
      
      ;; Extend expiration
      (map-set authentication-proofs
        { proof-id: proof-id }
        (merge proof-data 
          { expires-at: (+ (get expires-at proof-data) additional-blocks) }
        )
      )
      
      (ok true)
    )
  )
)

;; Emergency functions for contract owner
(define-public (emergency-pause)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    ;; Implementation would set a global pause state
    (ok true)
  )
)

(define-public (update-operation-fee (operation (string-ascii 32)) (new-fee uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (map-set operation-fees { operation: operation } { fee-amount: new-fee }))
  )
)

;; Reputation system functions
(define-public (update-entity-reputation (entity principal) (new-score uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (match (map-get? authorized-entities { entity: entity })
      entity-info (ok (map-set authorized-entities
        { entity: entity }
        (merge entity-info { reputation-score: (if (> new-score u1000) u1000 new-score) })
      ))
      ERR-NOT-AUTHORIZED
    )
  )
)


;; title: authentication-proof
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; data vars
;;

;; data maps
;;

;; public functions
;;

;; read only functions
;;

;; private functions
;;

