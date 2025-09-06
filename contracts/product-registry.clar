;; Product Registry Smart Contract
;; A comprehensive system for registering and managing product records with ownership tracking

;; Constants for error handling
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-PRODUCT-NOT-FOUND (err u201))
(define-constant ERR-PRODUCT-EXISTS (err u202))
(define-constant ERR-INVALID-OWNER (err u203))
(define-constant ERR-TRANSFER-FAILED (err u204))
(define-constant ERR-INVALID-STATUS (err u205))
(define-constant ERR-INSUFFICIENT-PERMISSIONS (err u206))
(define-constant ERR-INVALID-CATEGORY (err u207))

;; Contract owner for administrative functions
(define-constant CONTRACT-OWNER tx-sender)

;; Product status constants
(define-constant STATUS-MANUFACTURED "MANUFACTURED")
(define-constant STATUS-IN-TRANSIT "IN_TRANSIT")
(define-constant STATUS-DELIVERED "DELIVERED")
(define-constant STATUS-RECALLED "RECALLED")
(define-constant STATUS-DESTROYED "DESTROYED")

;; Core product registry data structure
(define-map product-registry
  { product-id: (string-ascii 64) }
  {
    manufacturer: principal,
    current-owner: principal,
    product-name: (string-utf8 128),
    category: (string-ascii 32),
    serial-number: (string-ascii 64),
    manufactured-date: uint,
    registered-date: uint,
    status: (string-ascii 32),
    specifications: (string-utf8 512),
    batch-id: (string-ascii 32),
    is-active: bool,
    transfer-count: uint,
    verification-hash: (buff 32)
  }
)

;; Product ownership transfer history
(define-map ownership-history
  { product-id: (string-ascii 64), transfer-id: uint }
  {
    from-owner: principal,
    to-owner: principal,
    transfer-date: uint,
    transfer-reason: (string-utf8 128),
    verification-signature: (optional (buff 65)),
    location: (string-utf8 64),
    is-verified: bool
  }
)

;; Authorized manufacturers and distributors
(define-map authorized-registrars
  { registrar: principal }
  {
    registrar-type: (string-ascii 32),
    company-name: (string-utf8 128),
    authorized-date: uint,
    is-active: bool,
    total-products-registered: uint,
    reputation-score: uint,
    allowed-categories: (list 10 (string-ascii 32))
  }
)

;; Product categories and their specifications
(define-map product-categories
  { category-name: (string-ascii 32) }
  {
    description: (string-utf8 128),
    required-fields: (list 5 (string-ascii 32)),
    verification-required: bool,
    retention-period: uint,
    is-active: bool
  }
)

;; Batch information for products
(define-map product-batches
  { batch-id: (string-ascii 32) }
  {
    manufacturer: principal,
    production-date: uint,
    expiry-date: (optional uint),
    total-items: uint,
    quality-score: uint,
    batch-status: (string-ascii 32),
    production-location: (string-utf8 64),
    certifications: (list 5 (string-ascii 32))
  }
)

;; Global counters and statistics
(define-data-var total-products-registered uint u0)
(define-data-var total-transfers uint u0)
(define-data-var total-active-products uint u0)
(define-data-var registry-version uint u1)

;; Product search indexes (simplified for this implementation)
(define-map products-by-manufacturer
  { manufacturer: principal, index: uint }
  { product-id: (string-ascii 64) }
)

(define-map products-by-category
  { category: (string-ascii 32), index: uint }
  { product-id: (string-ascii 64) }
)

;; Initialize default product categories
(map-set product-categories
  { category-name: "ELECTRONICS" }
  {
    description: u"Electronic devices and components",
    required-fields: (list "SERIAL" "MODEL" "WARRANTY" "SPECS" "CERTIFICATION"),
    verification-required: true,
    retention-period: u52560, ;; ~10 years
    is-active: true
  }
)

(map-set product-categories
  { category-name: "PHARMACEUTICALS" }
  {
    description: u"Medical drugs and pharmaceutical products",
    required-fields: (list "LOT_NUMBER" "EXPIRY" "DOSAGE" "ACTIVE_INGREDIENT" "FDA_APPROVAL"),
    verification-required: true,
    retention-period: u26280, ;; ~5 years
    is-active: true
  }
)

(map-set product-categories
  { category-name: "LUXURY" }
  {
    description: u"Luxury goods and high-value items",
    required-fields: (list "AUTHENTICITY_CERT" "APPRAISAL" "PROVENANCE" "MATERIALS" "CRAFTSMAN"),
    verification-required: true,
    retention-period: u105120, ;; ~20 years
    is-active: true
  }
)

;; Administrative functions
(define-public (authorize-registrar
    (registrar principal)
    (registrar-type (string-ascii 32))
    (company-name (string-utf8 128))
    (allowed-categories (list 10 (string-ascii 32)))
  )
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (map-set authorized-registrars
      { registrar: registrar }
      {
        registrar-type: registrar-type,
        company-name: company-name,
        authorized-date: block-height,
        is-active: true,
        total-products-registered: u0,
        reputation-score: u100,
        allowed-categories: allowed-categories
      }
    ))
  )
)

(define-public (revoke-registrar-authorization (registrar principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (match (map-get? authorized-registrars { registrar: registrar })
      registrar-info (ok (map-set authorized-registrars
        { registrar: registrar }
        (merge registrar-info { is-active: false })
      ))
      ERR-NOT-AUTHORIZED
    )
  )
)

;; Core product registration function
(define-public (register-product
    (product-id (string-ascii 64))
    (product-name (string-utf8 128))
    (category (string-ascii 32))
    (serial-number (string-ascii 64))
    (specifications (string-utf8 512))
    (batch-id (string-ascii 32))
    (verification-hash (buff 32))
  )
  (let
    (
      (registrar-info (unwrap! (map-get? authorized-registrars { registrar: tx-sender }) ERR-NOT-AUTHORIZED))
      (category-info (unwrap! (map-get? product-categories { category-name: category }) ERR-INVALID-CATEGORY))
      (existing-product (map-get? product-registry { product-id: product-id }))
    )
    (begin
      ;; Verify registrar authorization and category permissions
      (asserts! (get is-active registrar-info) ERR-NOT-AUTHORIZED)
      (asserts! (get is-active category-info) ERR-INVALID-CATEGORY)
      (asserts! (is-none existing-product) ERR-PRODUCT-EXISTS)
      
      ;; Verify category is allowed for this registrar
      (asserts! (is-some (index-of (get allowed-categories registrar-info) category)) ERR-INSUFFICIENT-PERMISSIONS)
      
      ;; Register the product
      (map-set product-registry
        { product-id: product-id }
        {
          manufacturer: tx-sender,
          current-owner: tx-sender,
          product-name: product-name,
          category: category,
          serial-number: serial-number,
          manufactured-date: block-height,
          registered-date: block-height,
          status: STATUS-MANUFACTURED,
          specifications: specifications,
          batch-id: batch-id,
          is-active: true,
          transfer-count: u0,
          verification-hash: verification-hash
        }
      )
      
      ;; Update counters and registrar stats
      (var-set total-products-registered (+ (var-get total-products-registered) u1))
      (var-set total-active-products (+ (var-get total-active-products) u1))
      
      ;; Update registrar statistics
      (map-set authorized-registrars
        { registrar: tx-sender }
        (merge registrar-info 
          {
            total-products-registered: (+ (get total-products-registered registrar-info) u1),
            reputation-score: (if (> (+ (get reputation-score registrar-info) u5) u1000) u1000 (+ (get reputation-score registrar-info) u5))
          }
        )
      )
      
      ;; Add to search indexes
      (map-set products-by-manufacturer
        { manufacturer: tx-sender, index: (get total-products-registered registrar-info) }
        { product-id: product-id }
      )
      
      (ok true)
    )
  )
)

;; Product ownership transfer function
(define-public (transfer-product-ownership
    (product-id (string-ascii 64))
    (new-owner principal)
    (transfer-reason (string-utf8 128))
    (verification-signature (optional (buff 65)))
    (location (string-utf8 64))
  )
  (let
    (
      (product-data (unwrap! (map-get? product-registry { product-id: product-id }) ERR-PRODUCT-NOT-FOUND))
      (current-transfers (get transfer-count product-data))
    )
    (begin
      ;; Verify current ownership
      (asserts! (is-eq tx-sender (get current-owner product-data)) ERR-NOT-AUTHORIZED)
      (asserts! (get is-active product-data) ERR-INVALID-STATUS)
      
      ;; Record the transfer in history
      (map-set ownership-history
        { product-id: product-id, transfer-id: current-transfers }
        {
          from-owner: tx-sender,
          to-owner: new-owner,
          transfer-date: block-height,
          transfer-reason: transfer-reason,
          verification-signature: verification-signature,
          location: location,
          is-verified: (is-some verification-signature)
        }
      )
      
      ;; Update product ownership and status
      (map-set product-registry
        { product-id: product-id }
        (merge product-data 
          {
            current-owner: new-owner,
            transfer-count: (+ current-transfers u1),
            status: STATUS-IN-TRANSIT
          }
        )
      )
      
      ;; Update global transfer counter
      (var-set total-transfers (+ (var-get total-transfers) u1))
      
      (ok true)
    )
  )
)

;; Batch product registration function
(define-public (register-product-batch
    (batch-id (string-ascii 32))
    (production-date uint)
    (expiry-date (optional uint))
    (total-items uint)
    (production-location (string-utf8 64))
    (certifications (list 5 (string-ascii 32)))
  )
  (let
    (
      (registrar-info (unwrap! (map-get? authorized-registrars { registrar: tx-sender }) ERR-NOT-AUTHORIZED))
    )
    (begin
      (asserts! (get is-active registrar-info) ERR-NOT-AUTHORIZED)
      
      (map-set product-batches
        { batch-id: batch-id }
        {
          manufacturer: tx-sender,
          production-date: production-date,
          expiry-date: expiry-date,
          total-items: total-items,
          quality-score: u100, ;; Default quality score
          batch-status: "ACTIVE",
          production-location: production-location,
          certifications: certifications
        }
      )
      
      (ok true)
    )
  )
)

;; Update product status function
(define-public (update-product-status
    (product-id (string-ascii 64))
    (new-status (string-ascii 32))
    (update-reason (string-utf8 128))
  )
  (let
    (
      (product-data (unwrap! (map-get? product-registry { product-id: product-id }) ERR-PRODUCT-NOT-FOUND))
    )
    (begin
      ;; Verify authorization (owner or manufacturer can update status)
      (asserts! (or 
        (is-eq tx-sender (get current-owner product-data))
        (is-eq tx-sender (get manufacturer product-data))
        (is-eq tx-sender CONTRACT-OWNER)
      ) ERR-NOT-AUTHORIZED)
      
      ;; Update product status
      (map-set product-registry
        { product-id: product-id }
        (merge product-data { status: new-status })
      )
      
      (ok true)
    )
  )
)

;; Product recall function
(define-public (recall-product (product-id (string-ascii 64)) (recall-reason (string-utf8 256)))
  (let
    (
      (product-data (unwrap! (map-get? product-registry { product-id: product-id }) ERR-PRODUCT-NOT-FOUND))
    )
    (begin
      ;; Only manufacturer or contract owner can recall
      (asserts! (or 
        (is-eq tx-sender (get manufacturer product-data))
        (is-eq tx-sender CONTRACT-OWNER)
      ) ERR-NOT-AUTHORIZED)
      
      ;; Update product status to recalled
      (map-set product-registry
        { product-id: product-id }
        (merge product-data { status: STATUS-RECALLED })
      )
      
      (ok true)
    )
  )
)

;; Batch recall function for multiple products
(define-public (batch-recall-products 
    (batch-id (string-ascii 32)) 
    (recall-reason (string-utf8 256))
  )
  (let
    (
      (batch-info (unwrap! (map-get? product-batches { batch-id: batch-id }) ERR-PRODUCT-NOT-FOUND))
    )
    (begin
      ;; Only batch manufacturer or contract owner can recall batch
      (asserts! (or 
        (is-eq tx-sender (get manufacturer batch-info))
        (is-eq tx-sender CONTRACT-OWNER)
      ) ERR-NOT-AUTHORIZED)
      
      ;; Update batch status
      (map-set product-batches
        { batch-id: batch-id }
        (merge batch-info { batch-status: "RECALLED" })
      )
      
      (ok true)
    )
  )
)

;; Read-only functions for querying registry data
(define-read-only (get-product-info (product-id (string-ascii 64)))
  (map-get? product-registry { product-id: product-id })
)

(define-read-only (get-product-transfer-history (product-id (string-ascii 64)) (transfer-id uint))
  (map-get? ownership-history { product-id: product-id, transfer-id: transfer-id })
)

(define-read-only (get-registrar-info (registrar principal))
  (map-get? authorized-registrars { registrar: registrar })
)

(define-read-only (get-batch-info (batch-id (string-ascii 32)))
  (map-get? product-batches { batch-id: batch-id })
)

(define-read-only (get-category-info (category-name (string-ascii 32)))
  (map-get? product-categories { category-name: category-name })
)

(define-read-only (is-product-authentic (product-id (string-ascii 64)))
  (match (map-get? product-registry { product-id: product-id })
    product-data (and 
      (get is-active product-data)
      (not (is-eq (get status product-data) STATUS-RECALLED))
    )
    false
  )
)

(define-read-only (get-registry-stats)
  {
    total-products: (var-get total-products-registered),
    active-products: (var-get total-active-products),
    total-transfers: (var-get total-transfers),
    registry-version: (var-get registry-version),
    contract-owner: CONTRACT-OWNER
  }
)

(define-read-only (get-manufacturer-stats (manufacturer principal))
  (match (map-get? authorized-registrars { registrar: manufacturer })
    registrar-info 
      {
        total-products-registered: (get total-products-registered registrar-info),
        reputation-score: (get reputation-score registrar-info),
        is-authorized: (get is-active registrar-info),
        company-name: (get company-name registrar-info),
        allowed-categories: (get allowed-categories registrar-info)
      }
    {
      total-products-registered: u0,
      reputation-score: u0,
      is-authorized: false,
      company-name: u"Unknown",
      allowed-categories: (list)
    }
  )
)

;; Product verification function
(define-read-only (verify-product-authenticity 
    (product-id (string-ascii 64))
    (expected-hash (buff 32))
  )
  (match (map-get? product-registry { product-id: product-id })
    product-data 
      {
        is-authentic: (is-eq (get verification-hash product-data) expected-hash),
        is-active: (get is-active product-data),
        current-status: (get status product-data),
        manufacturer: (get manufacturer product-data)
      }
    {
      is-authentic: false,
      is-active: false,
      current-status: "NOT_FOUND",
      manufacturer: CONTRACT-OWNER
    }
  )
)

;; Advanced search functions
(define-read-only (search-products-by-category (category (string-ascii 32)))
  ;; Simplified implementation - would require iteration in practice
  (ok true)
)

(define-read-only (search-products-by-batch (batch-id (string-ascii 32)))
  ;; Simplified implementation - would require iteration in practice
  (ok true)
)

;; Product lifecycle management
(define-public (deactivate-product (product-id (string-ascii 64)) (reason (string-utf8 128)))
  (let
    (
      (product-data (unwrap! (map-get? product-registry { product-id: product-id }) ERR-PRODUCT-NOT-FOUND))
    )
    (begin
      ;; Only manufacturer or owner can deactivate
      (asserts! (or 
        (is-eq tx-sender (get manufacturer product-data))
        (is-eq tx-sender (get current-owner product-data))
      ) ERR-NOT-AUTHORIZED)
      
      ;; Deactivate the product
      (map-set product-registry
        { product-id: product-id }
        (merge product-data { is-active: false, status: STATUS-DESTROYED })
      )
      
      ;; Update active product counter
      (var-set total-active-products (- (var-get total-active-products) u1))
      
      (ok true)
    )
  )
)

;; Emergency functions for contract maintenance
(define-public (emergency-update-registry-version)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (var-set registry-version (+ (var-get registry-version) u1))
    (ok (var-get registry-version))
  )
)

(define-public (add-product-category
    (category-name (string-ascii 32))
    (description (string-utf8 128))
    (required-fields (list 5 (string-ascii 32)))
    (verification-required bool)
    (retention-period uint)
  )
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (map-set product-categories
      { category-name: category-name }
      {
        description: description,
        required-fields: required-fields,
        verification-required: verification-required,
        retention-period: retention-period,
        is-active: true
      }
    ))
  )
)


;; title: product-registry
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

