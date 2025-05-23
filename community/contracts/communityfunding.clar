;; Community Funding Platform - Streamlined Version

;; Error codes
(define-constant ERR_UNAUTHORIZED (err u1))
(define-constant ERR_INVALID_INPUT (err u2))
(define-constant ERR_PROJECT_NOT_FOUND (err u3))
(define-constant ERR_PROJECT_INACTIVE (err u4))
(define-constant ERR_MILESTONE_NOT_FOUND (err u5))
(define-constant ERR_MILESTONE_ALREADY_COMPLETED (err u6))
(define-constant ERR_MILESTONE_NOT_COMPLETED (err u7))
(define-constant ERR_INSUFFICIENT_FUNDS (err u8))
(define-constant ERR_REFUND_NOT_AVAILABLE (err u9))
(define-constant ERR_DEADLINE_PASSED (err u10))

;; Constants
(define-constant FEE_PERCENTAGE u1) ;; 1% platform fee
(define-constant FEE_DENOMINATOR u100)
(define-constant ACTIVE u0)
(define-constant FUNDED u1)
(define-constant EXPIRED u2)
(define-constant COMPLETED u3)
(define-constant CANCELLED u4)

;; Data variables
(define-data-var next-id uint u1)
(define-data-var admin principal tx-sender)

;; Maps
(define-map projects { id: uint }
  {
    creator: principal,
    title: (string-utf8 100),
    description: (string-utf8 500),
    goal: uint,
    current: uint,
    deadline: uint,
    status: uint,
    milestone-count: uint
  }
)

(define-map milestones { project-id: uint, milestone-id: uint }
  {
    description: (string-utf8 200),
    amount: uint,
    completed: bool,
    released: bool
  }
)

(define-map funding { project-id: uint, funder: principal }
  {
    amount: uint,
    message: (optional (string-utf8 200)),
    refunded: bool
  }
)

;; Set platform admin
(define-public (set-admin (new-admin principal))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) ERR_UNAUTHORIZED)
    (ok (var-set admin new-admin))
  )
)

;; Create a new project
(define-public (create-project (title (string-utf8 100)) (description (string-utf8 500)) (goal uint) (deadline uint))
  (begin
    (asserts! (and (> (len title) u0) (> (len description) u0) (> goal u0) (> deadline stacks-block-height)) ERR_INVALID_INPUT)
    
    (let ((id (var-get next-id)))
      (map-set projects { id: id }
        {
          creator: tx-sender,
          title: title,
          description: description,
          goal: goal,
          current: u0,
          deadline: deadline,
          status: ACTIVE,
          milestone-count: u0
        }
      )
      
      (var-set next-id (+ id u1))
      (print { event: "project-created", id: id, creator: tx-sender, goal: goal })
      (ok id)
    )
  )
)

;; Add a milestone to a project
(define-public (add-milestone (project-id uint) (description (string-utf8 200)) (amount uint))
  (begin
    (asserts! (and (> project-id u0) (> (len description) u0) (> amount u0)) ERR_INVALID_INPUT)
    
    (let
      (
        (project (unwrap! (map-get? projects { id: project-id }) ERR_PROJECT_NOT_FOUND))
        (milestone-id (get milestone-count project))
      )
      (asserts! (is-eq tx-sender (get creator project)) ERR_UNAUTHORIZED)
      (asserts! (is-eq (get status project) ACTIVE) ERR_PROJECT_INACTIVE)
      
      (map-set milestones { project-id: project-id, milestone-id: milestone-id }
        {
          description: description,
          amount: amount,
          completed: false,
          released: false
        }
      )
      
      (map-set projects { id: project-id }
        (merge project { milestone-count: (+ milestone-id u1) })
      )
      
      (print { event: "milestone-added", project-id: project-id, milestone-id: milestone-id })
      (ok milestone-id)
    )
  )
)

;; Fund a project
(define-public (fund-project (project-id uint) (amount uint) (message (optional (string-utf8 200))))
  (begin
    (asserts! (and (> project-id u0) (> amount u0)) ERR_INVALID_INPUT)
    
    (let
      (
        (project (unwrap! (map-get? projects { id: project-id }) ERR_PROJECT_NOT_FOUND))
        (current-funding (default-to { amount: u0 } (map-get? funding { project-id: project-id, funder: tx-sender })))
        (fee (/ (* amount FEE_PERCENTAGE) FEE_DENOMINATOR))
        (project-amount (- amount fee))
      )
      (asserts! (is-eq (get status project) ACTIVE) ERR_PROJECT_INACTIVE)
      (asserts! (<= stacks-block-height (get deadline project)) ERR_DEADLINE_PASSED)
      
      (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
      
      (let ((new-amount (+ (get current project) project-amount)))
        (map-set projects { id: project-id }
          (merge project { 
            current: new-amount,
            status: (if (>= new-amount (get goal project)) FUNDED ACTIVE)
          })
        )
        
        (map-set funding { project-id: project-id, funder: tx-sender }
          {
            amount: (+ amount (get amount current-funding)),
            message: message,
            refunded: false
          }
        )
        
        (try! (as-contract (stx-transfer? fee tx-sender (var-get admin))))
        
        (print { event: "project-funded", project-id: project-id, amount: amount })
        (ok true)
      )
    )
  )
)

;; Mark a milestone as completed
(define-public (complete-milestone (project-id uint) (milestone-id uint))
  (begin
    (asserts! (and (> project-id u0) (>= milestone-id u0)) ERR_INVALID_INPUT)
    
    (let
      (
        (project (unwrap! (map-get? projects { id: project-id }) ERR_PROJECT_NOT_FOUND))
        (milestone (unwrap! (map-get? milestones { project-id: project-id, milestone-id: milestone-id }) ERR_MILESTONE_NOT_FOUND))
      )
      (asserts! (is-eq tx-sender (get creator project)) ERR_UNAUTHORIZED)
      (asserts! (or (is-eq (get status project) ACTIVE) (is-eq (get status project) FUNDED)) ERR_PROJECT_INACTIVE)
      (asserts! (not (get completed milestone)) ERR_MILESTONE_ALREADY_COMPLETED)
      
      (map-set milestones { project-id: project-id, milestone-id: milestone-id }
        (merge milestone { completed: true })
      )
      
      (print { event: "milestone-completed", project-id: project-id, milestone-id: milestone-id })
      (ok true)
    )
  )
)

;; Release funds for a completed milestone
(define-public (release-milestone-funds (project-id uint) (milestone-id uint))
  (begin
    (asserts! (and (> project-id u0) (>= milestone-id u0)) ERR_INVALID_INPUT)
    
    (let
      (
        (project (unwrap! (map-get? projects { id: project-id }) ERR_PROJECT_NOT_FOUND))
        (milestone (unwrap! (map-get? milestones { project-id: project-id, milestone-id: milestone-id }) ERR_MILESTONE_NOT_FOUND))
      )
      (asserts! (get completed milestone) ERR_MILESTONE_NOT_COMPLETED)
      (asserts! (not (get released milestone)) ERR_MILESTONE_ALREADY_COMPLETED)
      (asserts! (is-eq (get status project) FUNDED) ERR_PROJECT_INACTIVE)
      (asserts! (>= (get current project) (get amount milestone)) ERR_INSUFFICIENT_FUNDS)
      
      (try! (as-contract (stx-transfer? (get amount milestone) tx-sender (get creator project))))
      
      (map-set milestones { project-id: project-id, milestone-id: milestone-id }
        (merge milestone { released: true })
      )
      
      (map-set projects { id: project-id }
        (merge project { 
          current: (- (get current project) (get amount milestone)),
          status: (if (is-eq milestone-id (- (get milestone-count project) u1)) COMPLETED FUNDED)
        })
      )
      
      (print { event: "funds-released", project-id: project-id, milestone-id: milestone-id })
      (ok true)
    )
  )
)

;; Cancel a project (only creator or admin)
(define-public (cancel-project (project-id uint))
  (begin
    (asserts! (> project-id u0) ERR_INVALID_INPUT)
    
    (let ((project (unwrap! (map-get? projects { id: project-id }) ERR_PROJECT_NOT_FOUND)))
      (asserts! (or (is-eq tx-sender (get creator project)) (is-eq tx-sender (var-get admin))) ERR_UNAUTHORIZED)
      (asserts! (or (is-eq (get status project) ACTIVE) (is-eq (get status project) FUNDED)) ERR_PROJECT_INACTIVE)
      
      (map-set projects { id: project-id } (merge project { status: CANCELLED }))
      
      (print { event: "project-cancelled", project-id: project-id })
      (ok true)
    )
  )
)

;; Request a refund (if project is cancelled or expired)
(define-public (request-refund (project-id uint))
  (begin
    (asserts! (> project-id u0) ERR_INVALID_INPUT)
    
    (let
      (
        (project (unwrap! (map-get? projects { id: project-id }) ERR_PROJECT_NOT_FOUND))
        (user-funding (unwrap! (map-get? funding { project-id: project-id, funder: tx-sender }) ERR_INSUFFICIENT_FUNDS))
      )
      (asserts! 
        (or (is-eq (get status project) CANCELLED)
            (and (is-eq (get status project) ACTIVE) (> stacks-block-height (get deadline project))))
        ERR_REFUND_NOT_AVAILABLE)
      
      (asserts! (not (get refunded user-funding)) ERR_REFUND_NOT_AVAILABLE)
      
      (let
        (
          (amount (get amount user-funding))
          (fee (/ (* amount FEE_PERCENTAGE) FEE_DENOMINATOR))
          (refund (- amount fee))
        )
        (try! (as-contract (stx-transfer? refund tx-sender tx-sender)))
        
        (map-set funding { project-id: project-id, funder: tx-sender }
          (merge user-funding { refunded: true })
        )
        
        (if (and (is-eq (get status project) ACTIVE) (> stacks-block-height (get deadline project)))
          (map-set projects { id: project-id } (merge project { status: EXPIRED }))
          false
        )
        
        (print { event: "refund-processed", project-id: project-id, amount: refund })
        (ok refund)
      )
    )
  )
)

