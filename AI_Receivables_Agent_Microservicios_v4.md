# AI Receivables Agent — Arquitectura de microservicios API-first (v4.1)

> **Sustituye la arquitectura de la v3** (monolito modular). Se conservan el dominio de la v2 (máquinas de estado, reglas de dinero, ingesta CFDI, seguridad del agente, Promise-to-Pay, políticas, conciliación, canales, cumplimiento) y las correcciones técnicas de la v3, adaptadas a servicios distribuidos (§15).
>
> **API-first** significa aquí: cada servicio se define primero por sus **contratos** —OpenAPI 3.1 para lo síncrono y AsyncAPI 3.1 para eventos y comandos—; el código se genera y se implementa contra ellos. Ejemplo real en [`contracts/`](contracts/) (case-service).
>
> **[verificar]** = confirmar con documentación vigente del proveedor o con asesoría legal.
>
> **v4.1 (2026-10-02):** incorpora una revisión externa, con ajustes propios; el detalle está en §15.2.

---

# 0. Decisiones

| Tema | Decisión |
|------|----------|
| Estilo | **Microservicios API-first**, un servicio por *bounded context*, contrato antes que código |
| Servicios | **18 unidades desplegables en MVP 1:** 17 servicios propios (14 de dominio, inteligencia y lectura + 3 de borde) y el API Gateway (Envoy, que se configura, no se programa). F2 añade 4 servicios: 22 en total. Agrupar despliegues es una decisión abierta (§16) |
| Comunicación síncrona | REST/JSON con **OpenAPI 3.1**; API pública vía gateway, API interna `/internal/v1` solo dentro de la malla |
| Comunicación asíncrona | **Apache Kafka** gestionado; contratos **AsyncAPI 3.1**; sobre **CloudEvents 1.0**; esquemas JSON Schema en Schema Registry |
| Consistencia | **Outbox** transaccional + **inbox** idempotente en cada servicio; **sagas** orquestadas por el dueño del proceso |
| Datos | **Base de datos por servicio** (PostgreSQL 17), agrupadas en 4 clústeres RDS gestionados; RLS por tenant en todas |
| Lenguajes | **TypeScript** (Node.js 24 LTS, NestJS) para dominio y borde; **Python 3.13+** (FastAPI, Pydantic) para inteligencia (agente, documentos, riesgo); **SQL**; **HCL** para infraestructura |
| Plataforma | AWS región México: **EKS + Argo CD + Istio ambient + KEDA**, Envoy Gateway, RDS, MSK, S3, KMS **[verificar disponibilidad de servicios en `mx-central-1`]** |
| Origen de la decisión | El responsable del producto eligió microservicios en lugar del monolito modular de la v3. El costo en equipo, tiempo e infraestructura está cuantificado en §14 |

**Por qué el agente pasa a Python.** En la v3 se recomendaba TypeScript porque el agente llamaba a sus *tools* dentro del mismo proceso. Con microservicios cada *tool* ya es una llamada de red a otro servicio, así que esa ventaja desaparece. Python aporta el ecosistema de IA, ML y evaluación, y une a la gente de inteligencia en un solo lenguaje. Si el equipo es solo TypeScript, `agent-service` puede escribirse en TS **sin cambiar ningún contrato**.

---

# 1. Principios

1. **Contrato primero.** Ningún endpoint, evento o comando existe sin estar antes en `contracts/` revisado y aprobado por PR.
2. **Un dueño por dato.** Cada entidad tiene un único servicio que la escribe. Los demás la leen por API o mantienen una proyección local.
3. **Ningún servicio accede a la BD de otro** (ni réplicas, ni `dblink`/FDW, ni vistas compartidas).
4. **Las invariantes viven en su dueño.** Lo que no tolera consistencia eventual (saldos, pausas, opt-out, versión del caso) se valida en el servicio dueño, nunca contra una copia.
5. **El LLM propone, los servicios disponen** (v2 §3). El agente no escribe en ningún servicio: emite **un** comando que el orquestador valida.
6. **Todo efecto es idempotente y trazable** de extremo a extremo (`correlationId`, `traceparent`).
7. **Fail closed.** Si falta un permiso, una política o la respuesta de un dueño, no se contacta ni se mueve dinero: se escala a una persona.

---

# 2. Vista general

```text
   Web (Next.js)          Portal de pago          WhatsApp · Email · PSP · Bancos · IdP
        │                       │                                │ webhooks
        ▼                       ▼                                ▼
  AWS WAF → API Gateway (Envoy Gateway): JWT del IdP · rate limit por tenant · enrutamiento
        │                       │                                │
        ▼                       ▼                                ▼
     web-bff               portal-bff                     webhook-ingress
  (composición, SSE)    (enlaces firmados)         (firma · crudo · outbox)
        │                                                        │
        │ REST interno (OpenAPI) · mTLS · token de contexto       │
        ▼                                                        ▼
  Dominio — TypeScript / NestJS
    identity · customer · invoice · case (orquestador) · conversation · policy
    agreement · payment · ledger · task · document · audit
    dispute (F2) · integration (F2)
  Inteligencia — Python / FastAPI
    agent · knowledge (F2) · risk (F2)
  Lectura (CQRS) — TypeScript
    portfolio-query
        │ outbox                                         ▲ inbox
        ▼                                                │
  ═══ Kafka: <contexto>.events.v1 · <contexto>.commands.v1 · ingress.<proveedor>.v1 · retry/DLQ ═══
                      + Schema Registry (JSON Schema, compatibilidad BACKWARD_TRANSITIVE)

  Datos: una base PostgreSQL por servicio (4 clústeres RDS) · S3 · Valkey (solo gateway y BFF)
```

---

# 3. Catálogo de servicios

| # | Servicio | Lenguaje | Clúster / BD | Fase | Responsabilidad en una línea |
|---|----------|----------|--------------|------|------------------------------|
| E1 | `api-gateway` | Envoy Gateway | Valkey (rate limit) | F1 | Borde: autenticación, límites, enrutamiento |
| E2 | `web-bff` | TS | Valkey | F1 | API por pantalla para la web, SSE |
| E3 | `portal-bff` | TS | — | F1 | Portal público de pago del deudor |
| E4 | `webhook-ingress` | TS | ingress / `ingress_db` + S3 | F1 | Recibir y verificar webhooks; publicar crudo |
| S1 | `identity-service` | TS | core / `identity_db` | F1 | Tenants, configuración, RBAC, tokens internos |
| S2 | `customer-service` | TS | core / `customer_db` | F1 | Clientes deudores y contactos |
| S3 | `invoice-service` | TS | core / `invoice_db` | F1 | Facturas CFDI, importaciones, antigüedad |
| S4 | `integration-service` | TS | core / `integration_db` | F2 | Conectores ERP y estados de cuenta |
| S5 | `case-service` | TS | core / `case_db` | F1 | Expediente de cobranza y **orquestación** |
| S6 | `conversation-service` | TS | core / `conversation_db` | F1 | WhatsApp, email, mensajes, opt-out |
| S7 | `policy-service` | TS | core / `policy_db` | F1 | Decisiones deterministas: negociación y contacto |
| S8 | `agreement-service` | TS | core / `agreement_db` | F1 | Promesas y planes de pago |
| S9 | `payment-service` | TS | money / `payment_db` | F1 | PSP, links de pago, CLABEs virtuales |
| S10 | `ledger-service` | TS | money / `ledger_db` | F1 | Libro auxiliar de CxC, conciliación, **saldos** |
| S11 | `dispute-service` | TS | core / `dispute_db` | F2 | Disputas, evidencia, resolución |
| S12 | `task-service` | TS | core / `task_db` | F1 | Bandeja de trabajo humano |
| S13 | `document-service` | TS | core / `document_db` + S3 | F1 | Archivos, antivirus, URLs firmadas |
| S14 | `audit-service` | TS | read / `audit_db` + S3 Object Lock | F1 | Bitácora consolidada con cadena de hashes |
| S15 | `agent-service` | Python | ai / `agent_db` | F1 | Turnos del agente, propuestas, LLM |
| S16 | `knowledge-service` | Python | ai / `knowledge_db` (pgvector) | F2 | OCR, RAG híbrido con citas |
| S17 | `risk-service` | Python | ai / `risk_db` | F2 | Scoring heurístico (F2) y ML (F3) |
| S18 | `portfolio-query-service` | TS | read / `query_db` | F1 | Vistas de lectura (CQRS): listas, cartera, KPIs |

F3: `voice-service` (Python o proveedor), que emite los mismos eventos que `conversation-service` con canal `VOICE`.

---

# 4. Contratos por servicio

Convención de cada ficha:

```text
Dueño de    : datos que solo este servicio escribe
API pública : vía gateway/BFF, /v1/…
API interna : /internal/v1/… (x-internal: true; solo dentro de la malla)
Comandos ←  : comandos que acepta (Kafka)
Publica →   : eventos (y comandos que emite)
Consume ←   : eventos de otros servicios
```

## 4.1 Borde

### E2 · web-bff (TS)

```text
Rol         : única entrada de la app web; contratos orientados a pantalla; tiempo real por SSE
Estado      : sin BD de negocio (Valkey: caché corta + pub/sub para SSE entre réplicas)
API pública : GET /v1/pages/case-detail/{caseId}   compone case + ledger + agreement + conversation + tasks
              GET /v1/events/stream                 SSE por usuario/tenant
              resto: rutas tipadas que delegan en el servicio dueño (mismo contrato, sin lógica)
Llama a     : servicios de dominio con token de contexto (obtenido en identity-service)
Consume ←   : eventos relevantes para la UI (grupo bff-realtime) → SSE
```

### E3 · portal-bff (TS)

```text
Rol         : portal del deudor, sin login, con enlace firmado de vida corta
API pública : GET  /p/{linkToken}                    saldo y facturas incluidas en el enlace
              POST /p/{linkToken}/payment-intents    → payment-service
              POST /p/{linkToken}/documents          → document-service
              POST /p/{linkToken}/disputes   (F2)    → dispute-service
Seguridad   : token opaco no enumerable, alcance (tenant, cliente, facturas), expiración;
              validado en payment-service; rate limit estricto por IP y por token
```

### E4 · webhook-ingress (TS)

```text
Rol         : recibir webhooks, verificar firma sobre el cuerpo crudo, guardar, publicar. Sin lógica de negocio.
Dueño de    : inbox crudo cifrado; UNIQUE (provider, provider_event_id)
API pública : GET  /hooks/whatsapp                   verificación de suscripción de Meta
              POST /hooks/whatsapp · /hooks/email/{provider} · /hooks/psp/{provider} · /hooks/bank/{provider} · /hooks/idp
Publica →   : ingress.whatsapp.v1 · ingress.email.v1 · ingress.psp.v1 · ingress.bank.v1 · ingress.idp.v1
              (payload del proveedor, retención 3 días, ACL solo para el consumidor dueño)
SLO         : 99.95 % de disponibilidad; p99 < 500 ms; no resuelve el tenant (lo hace el consumidor, §7.6)
```

## 4.2 Dominio

### S1 · identity-service (TS)

```text
Dueño de    : organizaciones (tenants), configuración (zona horaria, moneda, nivel de autonomía L0–L3,
              calendario), membresías, roles y permisos
API pública : GET|PATCH /v1/organization        PUT /v1/organization/autonomy   (If-Match, auditado)
              GET|POST  /v1/members              PATCH /v1/members/{memberId}     GET /v1/roles
API interna : POST /internal/v1/token-exchange   token del IdP → token de contexto (5 min, aud por servicio)
              POST /internal/v1/capability-tokens token del agente acotado a (tenant, caso, permisos)
              GET  /.well-known/jwks.json
Publica →   : identity.events.v1: OrganizationCreated, OrganizationSettingsChanged, AutonomyLevelChanged, MemberChanged
Consume ←   : ingress.idp.v1 (altas y bajas de usuarios del IdP)
```

La autenticación (login, MFA, SSO/SAML) la hace el IdP (WorkOS o Clerk); este servicio gestiona tenancy, autorización y tokens internos.

**Disponibilidad.** identity-service está en el camino de todas las peticiones, así que su objetivo es 99.95 %: al menos 3 réplicas en 3 zonas y ninguna dependencia síncrona de otros servicios (firma con claves de KMS, membresías en su propia base con caché en memoria). Los demás servicios lo tratan como dependencia blanda: verifican los tokens localmente con el JWKS en caché y su *readiness* no depende de él (§9.1). También es dueño de la ruta "organización del IdP → tenant" (§7.6).

### S2 · customer-service (TS)

```text
Dueño de    : clientes deudores, contactos, verificación de contactos, fusión de duplicados, segmentos
API pública : GET|POST /v1/customers            GET|PATCH /v1/customers/{customerId}
              POST /v1/customers/{customerId}/merge
              GET|POST /v1/customers/{customerId}/contacts    PATCH /v1/contacts/{contactId}
              POST /v1/contacts/{contactId}/verification
API interna : GET  /internal/v1/contact-matches?phone=…|email=…   0, 1 o N contactos con sus clientes
              POST /internal/v1/customers:batch-upsert           idempotente por (source, externalId) o RFC
Publica →   : customer.events.v1: CustomerCreated, CustomerUpdated, CustomersMerged,
              ContactAdded, ContactUpdated, ContactVerified
```

### S3 · invoice-service (TS)

```text
Dueño de    : facturas (datos CFDI 4.0), notas de crédito, cancelaciones, importaciones CSV/XML,
              antigüedad y tick diario por tenant (umbrales de vencimiento en su zona horaria)
API pública : GET  /v1/invoices?customerId&status&dueBefore&cursor     GET /v1/invoices/{invoiceId}
              POST /v1/invoice-imports      → 202 + Location (archivo subido antes a document-service)
              GET  /v1/invoice-imports/{importId}     GET /v1/invoice-imports/{importId}/errors
API interna : POST /internal/v1/invoices:batch-get    GET /internal/v1/customers/{customerId}/open-invoices
Publica →   : invoice.events.v1: InvoiceIssued, InvoiceUpdated, InvoiceCancelled, CreditNoteIssued,
              InvoiceDueSoon, InvoiceBecameOverdue, InvoiceAgingBucketChanged, InvoiceImportCompleted
Consume ←   : ledger.events.v1 InvoiceBalanceChanged (proyección settlementStatus, solo lectura)
              identity.events.v1 (zona horaria del tenant)
Regla       : invoice-service es dueño del DOCUMENTO; ledger-service es dueño del SALDO.
```

### S4 · integration-service (TS, F2)

```text
Dueño de    : conexiones a ERP/contables, programación de sincronización, importación de estados de cuenta;
              capa anticorrupción hacia sistemas externos (credenciales en Secrets Manager)
API pública : GET|POST /v1/connections    POST /v1/connections/{connectionId}/sync    GET /v1/sync-runs/{runId}
Llama a     : invoice-service (POST /v1/invoice-imports) · customer-service (customers:batch-upsert) ·
              payment-service (POST /internal/v1/payments:import)
Publica →   : integration.events.v1: SyncRunCompleted, SyncRunFailed
```

### S5 · case-service (TS) — orquestador de cobranza

```text
Dueño de    : expedientes, facturas del caso (N:M, una sola activa por factura), máquina de estados,
              pausas y takeover, asignación, próxima acción, saga de cobranza (con acciones pendientes que esperan
              la confirmación de otra), permisos de contacto firmados
API pública : GET   /v1/cases/{caseId}                       PATCH /v1/cases/{caseId}   (If-Match)
              POST  /v1/cases/{caseId}/pause | resume | escalate | takeover | release | close
                    (If-Match + Idempotency-Key)
              GET   /v1/cases/{caseId}/timeline
API interna : GET   /internal/v1/cases/{caseId}/context            snapshot + versión (para el agente)
              POST  /internal/v1/cases/{caseId}/outbound-permits   permiso de contacto firmado (fail closed)
              GET   /internal/v1/customers/{customerId}/active-case
              GET   /internal/v1/permit-keys                       JWKS para verificar permisos
Comandos ←  : case.commands.v1: ApplyAgentDecision (todas las acciones de un turno, con expectedVersion)
Publica →   : case.events.v1: CaseOpened, CaseTransitioned, CasePaused, CaseResumed, CaseTakeoverStarted,
              CaseTakeoverEnded, CaseNextActionDue, CaseClosed, AgentDecisionApplied, CommandRejected
              conversation.commands.v1: SendMessage (con permiso) · agreement.commands.v1: ProposePromise,
              ConfirmPromise (con permiso) · dispute.commands.v1: OpenDispute (F2)
Consume ←   : invoice (InvoiceBecameOverdue, InvoiceCancelled, CreditNoteIssued) · ledger (InvoiceBalanceChanged) ·
              agreement (PromiseProposed, PromiseRejected, PromiseConfirmed, PromiseMissed, PromiseFulfilled) ·
              conversation (MessageSent) · dispute (DisputeOpened, DisputeResolved — F2) ·
              customer (CustomersMerged) · identity (AutonomyLevelChanged) · ops (MessageParked → pausa protectora)
Contrato    : contracts/openapi/case-service.yaml · contracts/asyncapi/case-service.yaml
```

La versión del caso **solo cambia con cambios del agregado** (estado, pausas, takeover, facturas, asignación), no con cada mensaje. Así un mensaje entrante no invalida el turno que el propio mensaje dispara.

### S6 · conversation-service (TS)

```text
Dueño de    : conversaciones, mensajes, plantillas (estado de aprobación en Meta), cuentas de canal y sus rutas a tenant (§7.6),
              preferencias y opt-out por canal, ventana de 24 h, estados de entrega, envío idempotente
API pública : GET  /v1/conversations?caseId=…              GET /v1/conversations/{conversationId}/messages
              POST /v1/conversations/{conversationId}/messages   (humano; Idempotency-Key; pide permiso a case-service)
              GET|POST /v1/templates      GET|PUT /v1/contacts/{contactId}/channel-preferences
              GET  /v1/channel-accounts
API interna : GET  /internal/v1/messages/{messageId}        cuerpo del mensaje (claim check; exige scope del caso)
              GET  /internal/v1/cases/{caseId}/recent-messages?limit=20
              GET  /internal/v1/contacts/{contactId}/reachability   canal, ventana abierta, consentimiento
Comandos ←  : conversation.commands.v1: SendMessage
Publica →   : conversation.events.v1: MessageReceived (sin cuerpo), MessageSent, MessageDelivered, MessageRead,
              MessageFailed, MessageDeliveryUnknown, ContactOptedOut, ContactOptedIn, InboundUnrouted, CommandRejected
Consume ←   : ingress.whatsapp.v1 · ingress.email.v1 · case.events.v1 (pausas y takeover → proyección local)
```

El **opt-out por canal** vive aquí y no en customer-service: se recibe por el canal y se aplica al enviar, así que su dueño es quien envía.

### S7 · policy-service (TS) — servicio de decisiones

```text
Dueño de    : políticas de negociación versionadas por alcance (tenant → segmento → cliente), reglas de contacto
              (horarios, frecuencia), calendarios hábiles y festivos, umbrales de aprobación, automatizaciones (F2)
API pública : GET|POST /v1/policies     POST /v1/policies/{policyId}/versions
              POST /v1/policies/{policyId}/versions/{version}/activate
              POST /v1/policy-simulations (F2)     GET|PUT /v1/contact-rules     GET|PUT /v1/business-calendars
API interna : POST /internal/v1/decisions/offer            ALLOW | REQUIRE_APPROVAL | DENY + motivos + policyVersion
              POST /internal/v1/decisions/allowed-offers   ofertas que el agente puede presentar
              POST /internal/v1/decisions/contact          ¿se puede contactar ahora? próxima ventana
              POST /internal/v1/decisions/next-action
Publica →   : policy.events.v1: PolicyVersionScheduled, PolicyVersionActivated, ContactRulesChanged
Versiones   : inmutables. Cada decisión devuelve policyVersion; dentro de un turno el agente la reenvía en las
              llamadas siguientes y cualquier réplica evalúa exactamente esa versión. Sin ella, se usa la vigente.
Activación  : programada (effective_from ≥ ahora + 60 s); PolicyVersionScheduled precarga las cachés para que
              todas las réplicas cambien a la vez
Operación   : funciones puras; ≥ 3 réplicas; caché por versión invalidada por evento (respaldo: TTL de 5 min)
```

Si la política cambia entre el turno y la ejecución, agreement-service evalúa con la vigente; si el resultado cambia, publica `PromiseRejected` y el agente repite el turno con la versión nueva.

### S8 · agreement-service (TS)

```text
Dueño de    : promesas de pago, planes y cuotas (F2), evaluación de cumplimiento,
              temporizadores (recordatorio previo y verificación posterior al vencimiento)
API pública : GET  /v1/cases/{caseId}/promises     POST /v1/cases/{caseId}/promises   (humano)
              POST /v1/promises/{promiseId}/confirm | cancel
              GET|POST /v1/cases/{caseId}/payment-plans (F2)    GET /v1/payment-plans/{planId} (F2)
API interna : GET  /internal/v1/cases/{caseId}/agreements      promesas y planes vigentes
Comandos ←  : agreement.commands.v1: ProposePromise, ConfirmPromise, ProposePaymentPlan (F2) — con permiso firmado
Publica →   : agreement.events.v1: PromiseProposed, PromiseRejected, PromiseConfirmed, PromiseReminderDue, PromiseFulfilled,
              PromisePartiallyFulfilled, PromiseMissed, PromiseCancelled, PromiseSuperseded, PlanInstallmentMissed (F2)
Consume ←   : ledger (PaymentAllocated, InvoiceBalanceChanged) · invoice (InvoiceCancelled) · case (CaseClosed)
Llama a     : policy-service /decisions/offer antes de crear o confirmar
```

### S9 · payment-service (TS)

```text
Dueño de    : medios de cobro (links de pago, CLABEs virtuales), pagos del PSP y de bancos, reversas y contracargos,
              cuentas PSP y sus rutas a tenant (§7.6); capa anticorrupción hacia el PSP
API pública : GET  /v1/payments?status&from&to&cursor     GET /v1/payments/{paymentId}
              POST /v1/cases/{caseId}/payment-links        GET /v1/customers/{customerId}/virtual-accounts
API interna : POST /internal/v1/payment-links              idempotente por Idempotency-Key (el agente necesita la URL)
              GET  /internal/v1/payment-links/{token}      validación para portal-bff
              POST /internal/v1/payments:import            estados de cuenta (F2)
Publica →   : payment.events.v1: PaymentReceived, PaymentConfirmed, PaymentFailed, PaymentReversed,
              PaymentLinkCreated, PaymentLinkExpired
Consume ←   : ingress.psp.v1 · ingress.bank.v1
Regla       : un pago pasa a CONFIRMED solo tras consultar su estado en la API del PSP, nunca por el webhook solo
```

### S10 · ledger-service (TS) — libro auxiliar y conciliación

```text
Dueño de    : cuentas por factura (proyección de total y moneda), pagos disponibles (proyección), asignaciones
              (diario append-only), notas de crédito aplicadas, castigos, diferencias cambiarias,
              motor de conciliación y SALDOS (autoridad única)
API pública : GET  /v1/ledger/invoices/{invoiceId}                 saldo + movimientos
              GET  /v1/reconciliation/unmatched-payments            candidatos y diferencias
              POST /v1/reconciliation/allocations                   manual (Idempotency-Key, If-Match del pago)
              POST /v1/ledger/allocations/{allocationId}/reversal
              POST /v1/ledger/invoices/{invoiceId}/write-offs       (permiso específico)
API interna : GET  /internal/v1/customers/{customerId}/balances    montos autoritativos para el agente
              POST /internal/v1/invoices:balances
Publica →   : ledger.events.v1: PaymentAllocated, AllocationReversed, InvoiceBalanceChanged, InvoiceSettled,
              PaymentUnmatched, CustomerCreditBalanceChanged
Consume ←   : invoice (InvoiceIssued, InvoiceUpdated, InvoiceCancelled, CreditNoteIssued) ·
              payment (PaymentConfirmed, PaymentReversed)
Invariantes : Σ asignaciones ≤ monto del pago · Σ asignaciones + créditos ≤ total de la factura
              (ambas en una sola BD: por eso el ledger guarda proyecciones de facturas y pagos)
```

Si un pago llega antes que su factura (importación tardía), queda `UNMATCHED` y el *matching* se reintenta cuando llega `InvoiceIssued`.

### S11 · dispute-service (TS, F2)

```text
Dueño de    : disputas, tipo, facturas afectadas, evidencia (referencias a documentos), SLA, resolución
API pública : GET /v1/disputes?status&cursor     POST /v1/cases/{caseId}/disputes    GET|PATCH /v1/disputes/{disputeId}
              POST /v1/disputes/{disputeId}/evidence     POST /v1/disputes/{disputeId}/resolve
Comandos ←  : dispute.commands.v1: OpenDispute
Publica →   : dispute.events.v1: DisputeOpened, DisputeEvidenceAdded, DisputeResolved, DisputeWithdrawn
Consume ←   : invoice (CreditNoteIssued → vincula la resolución aceptada)
En F1       : sin este servicio. La detección pausa las facturas en case-service (CasePaused, motivo DISPUTE)
              y task-service crea la tarea de revisión.
```

### S12 · task-service (TS)

```text
Dueño de    : bandeja de trabajo humano (aprobaciones, conciliación manual, números desconocidos,
              escalamientos, disputas por revisar), asignación, SLA, comentarios
API pública : GET /v1/tasks?type&status&assignee&cursor     GET /v1/tasks/{taskId}
              POST /v1/tasks/{taskId}/claim | release
Regla       : la decisión NO se toma aquí. Cada tarea apunta al recurso del dueño
              (p. ej. POST /v1/proposals/{proposalId}/approve en agent-service), que revalida
              y emite el evento que cierra la tarea.
Consume ←   : agent (ProposalCreated/Approved/Rejected/Expired/Stale) · ledger (PaymentUnmatched, PaymentAllocated) ·
              conversation (InboundUnrouted) · case (CasePaused motivo DISPUTE, CaseTransitioned → ESCALATED) · dispute (F2)
Publica →   : task.events.v1: TaskCreated, TaskAssigned, TaskClosed, TaskSlaBreached
```

### S13 · document-service (TS)

```text
Dueño de    : archivos y metadatos, SHA-256, antivirus, cuarentena, vínculos a entidades, URLs firmadas
API pública : POST /v1/document-uploads  → URL prefirmada     POST /v1/document-uploads/{uploadId}/complete
              GET  /v1/documents/{documentId}      GET /v1/documents/{documentId}/download-url
              GET  /v1/documents?entityType&entityId
API interna : POST /internal/v1/documents:ingest-from-url   medios de WhatsApp/email (allowlist anti-SSRF)
Publica →   : document.events.v1: DocumentUploaded, DocumentScanned (CLEAN | INFECTED), DocumentLinked
```

### S14 · audit-service (TS)

```text
Dueño de    : bitácora consolidada append-only con cadena de hashes por tenant (sellado periódico),
              expediente verificable; F3: sellado NOM-151 y anclaje Merkle
API pública : GET /v1/audit-events?entityType&entityId&cursor     GET /v1/cases/{caseId}/evidence-record (F2)
              POST /v1/evidence-verifications (F3, público)
Consume ←   : *.events.v1 (todos)
Regla       : las acciones críticas (aprobaciones, cambios de política o autonomía, conciliación manual) también
              se registran en la BD del servicio dueño en la misma transacción; audit-service consolida y sella.
```

## 4.3 Inteligencia

### S15 · agent-service (Python)

```text
Dueño de    : turnos del agente, propuestas pendientes de aprobación, registro de prompts y versiones,
              enrutamiento de modelos, trazas de LLM (PII redactada), costo por tenant, feedback, datasets de evals
API pública : GET  /v1/cases/{caseId}/agent-turns     GET /v1/agent-turns/{turnId}   (explicabilidad)
              GET  /v1/proposals/{proposalId}
              POST /v1/proposals/{proposalId}/approve | reject | edit-and-approve   (If-Match; revalida)
              POST /v1/agent-turns/{turnId}/feedback
Consume ←   : conversation (MessageReceived) · case (CaseNextActionDue, CommandRejected, AgentDecisionApplied) ·
              agreement (PromiseRejected, PromiseMissed, PromiseReminderDue) · identity (AutonomyLevelChanged)
Tools       : con token de capacidad del caso → case /context · conversation /recent-messages, /messages/{id}
              y /contacts/{id}/reachability · ledger /balances · agreement /agreements · policy /decisions/* ·
              payment /payment-links · knowledge /retrievals (F2) · risk (F2)
Comandos →  : case.commands.v1: ApplyAgentDecision (todas las acciones del turno juntas, con expectedVersion
              y expiresAt)
Publica →   : agent.events.v1: AgentTurnCompleted, IntentsDetected, ProposalCreated, ProposalApproved,
              ProposalRejected, ProposalExpired, ProposalStale
```

- **Un turno por caso a la vez.** Esto ya no se garantiza con un bloqueo de transacción. El consumidor registra `turn_requests` con *debounce* (4 s) y un worker toma un *lease* por caso (`SELECT … FOR UPDATE SKIP LOCKED` sobre `case_agent_state`). El lease dura 90 s y se renueva con un *heartbeat* cada 20 s, también durante la llamada al LLM. La latencia del LLM no bloquea la partición de Kafka.
- **Fencing token:** cada vez que se toma el lease se incrementa `lease_epoch`, y toda escritura del turno lleva `WHERE lease_epoch = <la mía>`. Así, un worker que despierta tarde no puede sobrescribir el estado. Que una decisión se aplique dos veces ya lo impide `expectedVersion` en case-service.
- **Turno reanudable:** `STARTED → LLM_DONE → POLICY_DONE → DECISION_SENT → APPLIED | REJECTED | EXPIRED`, o `AWAITING_APPROVAL`. Si el worker muere después del LLM, no se vuelve a pagar la llamada: el sweeper de turnos atascados (cada 5 min) retoma desde el último estado guardado.
- El **LLM gateway** es un módulo interno (proveedor, *fallback*, *prompt caching*, presupuesto por tenant). Si en F2 otros servicios usan LLM, se separa como `llm-gateway`.

### S16 · knowledge-service (Python, F2)

```text
Dueño de    : OCR y layout, extracción de documentos no CFDI, chunks, embeddings, recuperación híbrida con citas
API interna : POST /internal/v1/retrievals    filtros obligatorios tenant/cliente/caso → chunks con procedencia
              POST /internal/v1/extractions   → 202
Consume ←   : document (DocumentScanned = CLEAN, DocumentLinked)
Publica →   : knowledge.events.v1: DocumentIndexed, ExtractionCompleted
```

### S17 · risk-service (Python, F2 heurístico · F3 ML)

```text
Dueño de    : features por cliente; scores (propensión de pago, probabilidad de disputa, tiempo esperado)
              con versión de modelo y factores principales
API interna : GET /internal/v1/customers/{customerId}/risk
Consume ←   : invoice · ledger · agreement · dispute
Publica →   : risk.events.v1: RiskScoreUpdated
Batch       : scoring nocturno; entrenamiento offline con registro de modelos (F3)
```

## 4.4 Lectura

### S18 · portfolio-query-service (TS) — CQRS

```text
Dueño de    : vistas desnormalizadas: lista de casos, cartera por antigüedad, KPIs, resumen por cliente, inbox
API pública : GET /v1/portfolio/summary     GET /v1/portfolio/aging     GET /v1/kpis?from&to
              GET /v1/case-views?status&risk&bucket&assignee&q&sort&cursor
              GET /v1/customer-views/{customerId}     GET /v1/inbox?cursor
Consume ←   : customer · invoice · ledger · case · agreement · conversation · risk · dispute · task
SLO         : evento → vista p95 < 5 s; cada respuesta incluye asOf (frescura)
Reconstruir : exportación desde cada dueño (instantánea) + re-consumo de los últimos 90 días (§6.2)
```

Las listas filtrables y ordenables (casos por saldo, riesgo y último mensaje) **no pueden** componerse en vivo desde 6 servicios. Por eso existe este servicio. Sus tablas tienen RLS y no se usan vistas materializadas.

---

# 5. Patrones aplicados

| Patrón | Dónde | Para qué |
|--------|-------|----------|
| API Gateway | Envoy Gateway | Autenticación de borde, rate limit, enrutamiento |
| Backend for Frontend | web-bff, portal-bff | Contratos por pantalla; aislar el portal público |
| Database per Service | Todos | Autonomía; sin joins ni FKs entre servicios |
| Transactional Outbox | Todo servicio que publica | Sin *dual write* BD ↔ Kafka |
| Idempotent Consumer (inbox) | Todo consumidor | Entrega *at-least-once* sin efectos dobles |
| Saga orquestada | case-service (cobranza), agreement-service (ciclo de la promesa) | Procesos largos con recuperación y compensación (§8.5) |
| Saga coreografiada | audit, portfolio-query, task, invoice (settlementStatus) | Reacciones simples sin coordinador |
| CQRS | portfolio-query-service | Listas y dashboard sin componer N servicios |
| API Composition | web-bff (pantallas de detalle) | Lecturas puntuales de varios dueños |
| Diario inmutable (event-sourced) | ledger-service | Movimientos de dinero verificables y reversibles |
| Anti-Corruption Layer | webhook-ingress + adaptadores en conversation, payment e integration | Aislar los modelos de Meta, PSP y ERP |
| Claim Check | MessageReceived y eventos con PII | Kafka no replica contenido sensible |
| Capability token | identity → agent-service; case-service → permisos de contacto | Autoridad acotada y verificable |
| Circuit breaker, timeout, retry, bulkhead | Chasis | Evitar fallas en cascada |
| Retry topics + Dead Letter | Todo consumidor | Errores aislados y reprocesables |
| Microservice Chassis + Service Template | `libs/chassis-ts`, `libs/chassis-py`, `tools/create-service` | Que todos los servicios se construyan igual |
| Health Check API | `/health/live`, `/health/ready` | Despliegues seguros |
| Externalized Configuration | ConfigMaps, External Secrets, OpenFeature | Configuración y flags fuera del código |
| Observabilidad distribuida | OpenTelemetry (HTTP + Kafka) | Seguir un caso de punta a punta |
| Consumer-Driven Contracts | Pact + Schema Registry | Romper un contrato falla en CI, no en producción |

---

# 6. Comunicación

## 6.1 Reglas

1. **Escrituras entre servicios: asíncronas**, como comando o evento por Kafka publicado con outbox.
   *Excepción:* una llamada síncrona se permite si (a) es idempotente por clave y (b) el llamador necesita la respuesta para continuar. Casos aprobados: `customers:batch-upsert`, `payment-links`, `outbound-permits`, aprobaciones humanas.
2. **Lecturas:** API interna síncrona con *timeout* (1 s por defecto, presupuesto total por request; tabla en §6.5), o proyección local si la lectura es frecuente y tolera segundos de retraso.
3. **Invariantes en el dueño:** versión esperada (`expectedVersion`) y permisos firmados; nunca validar contra una copia.
4. **Máximo 2 saltos síncronos encadenados**, sin ciclos (se verifica sobre el grafo que sale de los contratos).
5. **Eventos** = hechos en pasado con muchos consumidores (`PaymentConfirmed`). **Comandos** = imperativos con un único dueño (`SendMessage`).
6. Todo mensaje lleva `tenantId`, `aggregateVersion`, `correlationId`, `causationId` y `traceparent`.
7. **Consumidores tolerantes a desorden:** comparan `aggregateVersion`; ante un hueco, se re-sincronizan con la API del dueño.
8. **Comandos con vencimiento:** todo comando lleva `expiresAt` y el dueño rechaza los vencidos (`CommandRejected`, motivo `EXPIRED`). Un comando no se reintenta: si vence sin respuesta, se decide de nuevo con contexto fresco (§6.5).

## 6.2 Topics de Kafka

| Topic | Productor | Key | Particiones | Retención |
|-------|-----------|-----|-------------|-----------|
| `<contexto>.events.v1` | Servicio dueño | Id del agregado | 12 | 90 días |
| `<contexto>.commands.v1` | Orquestador | Id del agregado destino | 12 | 7 días |
| `ingress.<proveedor>.v1` | webhook-ingress | Cuenta + remitente | 6 | 3 días |
| `<grupo>.retry.<n>` / `<grupo>.dlq` | Chasis | Igual al original | = original | 14 / 30 días |

- ACL por servicio: solo el dueño produce en sus topics y cada consumidor está declarado en su AsyncAPI.
- El orden está garantizado **por agregado** dentro de un topic; entre topics no hay orden (de ahí la regla 7).
- Schema Registry con compatibilidad `BACKWARD_TRANSITIVE`. Un cambio incompatible crea `.v2` con doble publicación durante la migración.
- **Sin datos personales en los eventos:** llevan IDs y datos de negocio. Nombres, RFC, teléfonos y emails se consultan por API (*claim check*), así que la retención no choca con el derecho de cancelación (ARCO).
- **Retención infinita** (*tiered storage* en S3) solo para topics sin datos personales que la auditoría requiera, como `ledger.events.v1`.
- **Reconstrucción de una proyección:** exportación desde cada dueño (`GET /internal/v1/<recurso>:export?cursor=…`, una instantánea) y luego re-consumo de los últimos 90 días.

## 6.3 Sobre de los mensajes

```text
Key      : caseId (id del agregado)
Headers  : ce_specversion=1.0 · ce_id=<uuid v7> · ce_source=/case-service
           ce_type=com.receivables.case.transitioned.v1 · ce_time=2026-10-01T16:00:00Z
           ce_tenantid=<orgId> · ce_correlationid=<flujo> · ce_causationid=<mensaje que lo causó>
           traceparent=00-… · content-type=application/json
Valor    : { "caseId": "…", "aggregateVersion": 18, "from": "NEGOTIATING", "to": "PROMISE_ACTIVE",
             "reason": "PROMISE_CONFIRMED", "actor": { "type": "SYSTEM" } }
```

## 6.4 Permisos de contacto firmados

La invariante "no contactar si el caso está pausado, en disputa, en takeover o cerrado" pertenece a **case-service**. Este servicio emite permisos de vida corta que el ejecutor verifica sin volver a llamarlo:

```text
permit = JWS firmado por case-service (claves en /internal/v1/permit-keys)
{ "tid": "<orgId>", "caseId": "…", "caseVersion": 18, "scope": ["SEND_MESSAGE"], "exp": <ahora + 60 s>, "jti": "…" }
```

- **Ruta asíncrona** (agente): case-service incluye el permiso en `SendMessage` o `ProposePromise` al aplicar la decisión.
- **Ruta síncrona** (persona que escribe en el inbox): conversation-service pide el permiso a `POST /internal/v1/cases/{caseId}/outbound-permits`. Si no hay respuesta, no se envía.
- conversation-service verifica además su proyección local de pausas. La ventana residual es menor que el TTL del permiso menos la latencia de propagación, y está documentada.

**Quién verifica qué.** Las dos verificaciones fallan cerradas por separado:

| Verificación | Dueño | Cuándo |
|---|---|---|
| Estado del caso: pausa, takeover, disputa, cierre, versión | case-service | Al emitir el permiso |
| Estado del canal: opt-out, ventana de 24 h, plantilla aprobada, calidad del número | conversation-service | Al enviar |

El agente consulta `/reachability` antes de redactar, para no proponer mensajes que no se podrán enviar, y web-bff la usa para mostrar en la UI el motivo cuando no se puede enviar.

## 6.5 Comandos con respuesta, timeouts y reintentos

`ApplyAgentDecision` espera respuesta: `AgentDecisionApplied` o `CommandRejected`, correlacionadas por `commandId` (`ce_causationid`).

- El comando lleva `expiresAt` (por defecto, ahora + 2 min). case-service rechaza los vencidos con motivo `EXPIRED`, así que un comando atrasado nunca actúa después de que el agente lo dio por perdido.
- Si no hay respuesta 30 s después de `expiresAt`, el turno pasa a `EXPIRED` y empieza uno nuevo con contexto fresco. Tras dos turnos vencidos seguidos, se crea una tarea humana.
- Un comando no se reintenta: el outbox garantiza que se publica, y el inbox del dueño descarta un procesamiento duplicado.

| Tipo de llamada | Timeout | Reintentos | Si falla |
|---|---|---|---|
| REST interno de lectura | 1 s | Hasta 2, con espera aleatoria (*jitter*), solo en el origen de la cadena y con un límite global del 10 % de las llamadas | Fail closed o degradación documentada |
| REST interno con efecto | 2 s | Solo con `Idempotency-Key`, con la misma regla | Fail closed |
| Comando por Kafka con respuesta | `expiresAt` + 30 s | Ninguno | Turno nuevo; tarea humana tras 2 vencimientos |
| Llamada al LLM | 30 s | 1, con el modelo de respaldo | Plantilla segura + tarea humana |
| Webhook saliente a sistemas del tenant (F2) | 10 s | 3, con espera exponencial | DLQ + alerta |

Reintentar en cada salto multiplica la carga: con 2 reintentos por salto y 2 saltos, el último servicio recibe hasta 9 llamadas. Por eso solo reintenta quien origina la cadena.

---

# 7. Datos

## 7.1 Base de datos por servicio, en 4 clústeres

| Clúster RDS PostgreSQL 17 (Multi-AZ, PITR) | Bases de datos | Por qué juntas |
|--------------------------------------------|----------------|----------------|
| `core` | identity, customer, invoice, case, conversation, policy, agreement, task, document, dispute, integration | Carga OLTP moderada |
| `money` | payment, ledger | Radio de impacto y acceso más estrictos (dinero) |
| `ai` | agent, knowledge (pgvector), risk | Cargas de escritura y vectores distintas |
| `read` + `ingress` | portfolio-query, audit · ingress | Lectura intensiva / append-only |

- **Separación lógica estricta:** base de datos y credenciales propias por servicio; ningún rol puede conectarse a otra base. Un servicio se mueve a su propio clúster cuando sus métricas lo piden (el primer candidato es `conversation_db`).
- **Otros almacenes:** S3 (documentos, crudos de webhooks, lotes de auditoría con Object Lock) y Valkey solo en gateway y BFF. Más adelante: ClickHouse (F3) para analítica histórica.

## 7.2 Dentro de cada base

- RLS por tenant con `app.current_org()` (`NULLIF(current_setting('app.current_org', true), '')::uuid`), `FORCE ROW LEVEL SECURITY`, rol de la app sin `BYPASSRLS` y FKs compuestas `(organization_id, id)`. Todo viene en la **migración base del chasis**, igual para todos los servicios.
- Dinero en `numeric(19,4)` + `currency char(3)`; en código, `decimal.js` (TS) o `decimal.Decimal` (Python), validados con los **mismos vectores de prueba** (`contracts/test-vectors/`).
- Transacciones cortas por caso de uso; nunca una llamada de red dentro de una transacción abierta.

## 7.3 Outbox, inbox y orden

```sql
-- En cada servicio que publica
CREATE TABLE outbox (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  organization_id uuid NOT NULL,
  aggregate_type text NOT NULL, aggregate_id uuid NOT NULL, aggregate_version int NOT NULL,
  topic text NOT NULL, message_key text NOT NULL,
  ce_type text NOT NULL, headers jsonb NOT NULL, payload jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(), published_at timestamptz
);
CREATE INDEX outbox_pending ON outbox (id) WHERE published_at IS NULL;

-- En cada servicio que consume
CREATE TABLE inbox (
  consumer text NOT NULL, message_id uuid NOT NULL,          -- ce_id
  processed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (consumer, message_id)
);
```

- **Regla de orden:** todo evento de un agregado se inserta en la misma transacción que incrementa su `version`. Como esas transacciones se serializan sobre la fila del agregado, el `id` del outbox respeta el orden por agregado.
- **Relay:** un solo relay activo por servicio (*lease*), que publica en orden de `id` y marca `published_at`. Si el volumen lo exige, se migra a CDC con Debezium.
- **Consumidor:** inserta en `inbox` y aplica el efecto en la misma transacción; confirma el *offset* después del *commit*.

## 7.4 Referencias entre servicios

- Entre servicios solo hay **IDs, sin FKs**. La validez se comprueba al aceptar un comando (API del dueño o proyección).
- Fusiones y bajas se propagan por evento (`CustomersMerged { fromId, toId }`), y cada consumidor re-apunta sus referencias.
- Los datos de referencia de otros dueños (zona horaria del tenant, pausas del caso, total de la factura en el ledger) se guardan como **proyecciones** con `source_version`.

## 7.5 Temporizadores

Cada servicio es dueño de sus temporizadores. Usa columnas `*_at` en su BD y *sweepers* del chasis (un líder por servicio mediante *advisory lock*). No hay un servicio central de temporizadores ni un motor de workflows.

| Servicio | Temporizador |
|----------|--------------|
| invoice-service | Tick diario por tenant, en su zona horaria (por vencer, vencida, cambio de bucket) |
| case-service | `next_action_at` → `CaseNextActionDue` |
| agreement-service | Recordatorio previo y verificación posterior a `promised_date` |
| conversation-service | Envíos en `SENDING` sin confirmación → `MessageDeliveryUnknown` |
| agent-service | Turnos atascados; propuestas vencidas → `ProposalExpired` |
| task-service | SLA de tareas |
| audit-service | Sellado de la cadena de hashes |

## 7.6 Resolución del tenant en entradas externas

Un webhook llega antes de saber de qué tenant es, y con la RLS activa una búsqueda sin tenant devuelve 0 filas: el mensaje no se podría enrutar. Por eso cada dueño de una integración guarda una tabla de rutas global, **sin RLS**:

```sql
CREATE TABLE provider_routes (
  provider        text NOT NULL,   -- WHATSAPP | EMAIL | PSP_<nombre> | BANK_<nombre> | IDP
  external_id     text NOT NULL,   -- phone_number_id, dominio de entrada, cuenta PSP o bancaria, organización del IdP
  organization_id uuid NOT NULL,
  PRIMARY KEY (provider, external_id)   -- un identificador externo pertenece a un solo tenant
);
-- Sin RLS. Solo la lee el rol de ingesta del servicio. La escribe el alta de la integración,
-- en la misma transacción que la cuenta de canal o de PSP.
```

| Identificador externo | Dueño de la ruta |
|---|---|
| `phone_number_id` de WhatsApp, dominio de email entrante | conversation-service |
| Cuenta del PSP, cuenta bancaria | payment-service |
| Organización del IdP | identity-service |

El consumidor resuelve el tenant en esta tabla y solo después fija el tenant de la transacción (`app.current_org`). Se descartó centralizar todas las rutas en identity-service: añadiría una llamada síncrona por webhook y agravaría su papel de punto único de fallo.

---

# 8. Flujos críticos

## 8.1 Mensaje entrante → respuesta del agente

```text
1  WhatsApp → gateway → webhook-ingress
     firma sobre cuerpo crudo → INSERT inbox (provider, event_id) + outbox → 200
     → ingress.whatsapp.v1
2  conversation-service
     inbox idempotente · tenant = provider_routes[WHATSAPP, phone_number_id]     ← tabla sin RLS (§7.6)
     contacto = customer-service GET /internal/v1/contact-matches?phone=…   (0 / 1 / N)
       0 → respuesta genérica sin datos + InboundUnrouted (tarea)
       N → pregunta de desambiguación con plantilla, sin revelar montos
     caso = conversación abierta del contacto, o case-service GET …/customers/{id}/active-case
     INSERT message (UNIQUE provider_message_id) + outbox MessageReceived { caseId, messageId }   ← sin cuerpo
3  agent-service
     inbox · upsert turn_request (caseId, run_after = ahora + 4 s)              ← debounce
     worker: lease por caso → token de capacidad (identity-service, alcance = caso)
       lecturas en paralelo: case /context (versión v) · mensajes · reachability · saldos · promesas ·
                             ofertas permitidas (fija la versión de política p)
       LLM → validación Pydantic → extractores deterministas → policy /decisions/* (con p)
       L1: Proposal (expectedVersion = v) + ProposalCreated → task-service crea la tarea
       L2 y permitido: outbox → ApplyAgentDecision { expectedVersion: v, expiresAt: ahora + 2 min, actions }
4  case-service
     inbox · ¿vencido? → CommandRejected { reason: EXPIRED }
     bloquea el caso · ¿version == v y estado compatible?
       no → CommandRejected { reason: STALE_VERSION } → agent-service repite el turno (máx. 2, luego escala)
       sí → transiciones + AgentDecisionApplied + comandos con permiso, en una transacción.
            Una acción que depende de otra espera su confirmación: con PROPOSE_PROMISE, el SendMessage
            de confirmación sale solo al llegar PromiseProposed; con PromiseRejected no sale (§8.5)
5  conversation-service
     verifica permiso (firma, exp, caseVersion) + opt-out + ventana de 24 h / plantilla
     QUEUED → SENDING → proveedor (client_ref) → SENT + MessageSent
6  case-service (MessageSent → AWAITING_REPLY) · audit · portfolio-query · web-bff (SSE)
```

## 8.2 Pago → conciliación → promesa cumplida → caso resuelto

```text
1  PSP → webhook-ingress → ingress.psp.v1
2  payment-service: tenant = provider_routes[PSP, cuenta] (§7.6); consulta el pago en la API del PSP;
     Payment CONFIRMED → PaymentConfirmed
3  ledger-service: matching determinista (CLABE virtual / referencia) →
     bloquea pago + facturas en orden de id → asignaciones → PaymentAllocated + InvoiceBalanceChanged
     sin match → PaymentUnmatched → task-service: conciliación manual
4  invoice-service  : proyección settlementStatus (PAID / PARTIALLY_PAID)
   agreement-service: evalúa promesas → PromiseFulfilled | PromisePartiallyFulfilled
   case-service     : saldo de todas sus facturas = 0 → RESOLVED
5  Reversa (saga inversa, §8.5): PaymentReversed → ledger: REVERSAL → InvoiceBalanceChanged →
   case RESOLVED → OUTREACH (motivo PAYMENT_REVERSED, sin close_reason); agreement re-evalúa la promesa
```

## 8.3 Aprobación humana sin TOCTOU

```text
web-bff → agent-service POST /v1/proposals/{id}/approve  (If-Match: versión de la propuesta)
  agent-service: ¿PENDING y no vencida? → vuelve a pedir policy /decisions/* con datos actuales
  → ApplyAgentDecision { expectedVersion: versión del caso al proponer }
  case-service rechaza si el caso cambió → ProposalStale → la UI muestra "el caso cambió: regenerar"
  Si se cerró la ventana de 24 h → el texto libre se convierte en propuesta de plantilla
```

## 8.4 Importación de facturas

```text
web-bff → document-service (subida) → invoice-service POST /v1/invoice-imports → 202 { importId }
invoice-service, por bloques de 500 filas y con prioridad baja:
  parseo determinista (CFDI XML / CSV) → customer-service customers:batch-upsert (idempotente)
  → upsert de facturas → outbox InvoiceIssued / InvoiceUpdated → InvoiceImportCompleted
tick diario → InvoiceBecameOverdue → case-service abre o actualiza el caso
```

## 8.5 Recuperación y compensaciones

Cada paso de una saga es de uno de tres tipos:

| Tipo | Qué es | Si un paso posterior falla |
|---|---|---|
| Reintentable | Interno e idempotente | Se reintenta hasta lograrlo (recuperación hacia adelante); no se deshace nada |
| Pivote | Efecto externo irreversible: pago confirmado por el PSP, mensaje enviado | Desde aquí solo se avanza; por eso va lo más tarde posible |
| Compensable | Estado interno que puede quedar sin efecto | Se compensa con una acción inversa registrada, nunca borrando |

Una reversa de pago (contracargo o devolución) no es una compensación por fallo: es un hecho de negocio nuevo que dispara la saga inversa. Toda compensación es idempotente y lleva el `ce_causationid` del mensaje que la originó.

**§8.1 · Mensaje entrante → respuesta**

| Paso | Tipo | Si falla después |
|---|---|---|
| Mensaje guardado (`MessageReceived`) | Reintentable | — |
| Turno del agente | Reintentable (reanudable) | Turno nuevo; tarea humana tras 2 fallos |
| Acciones aplicadas por case-service | Reintentable, en orden de dependencia | Si llega `PromiseRejected`, el mensaje que dependía de la promesa no se emite y el agente repite el turno |
| Promesa `PROPOSED` | Compensable | Si el cliente no confirma a tiempo, vence → `PromiseCancelled` |
| Mensaje enviado | **Pivote** | No se puede deshacer: sale al final y solo con permiso vigente |

**§8.2 · Pago → caso resuelto**

| Paso | Tipo | Si falla después |
|---|---|---|
| `PaymentConfirmed` | **Pivote** (hecho externo) | No se deshace; los pasos siguientes se reintentan |
| Asignación en el ledger | Reintentable | Sin coincidencia → conciliación manual |
| Evaluación de la promesa | Reintentable | — |
| Caso `RESOLVED` | Reintentable | — |
| Saga inversa (`PaymentReversed`) | — | Asignación `REVERSAL` (fila nueva, nunca UPDATE) → saldo → promesa re-evaluada → caso `RESOLVED → OUTREACH` |

**§8.3 · Aprobación:** si case-service rechaza (`STALE_VERSION` o `EXPIRED`), la propuesta pasa a `STALE` y no se envía nada; no hay nada que compensar.

**§8.4 · Importación:** cada bloque de 500 filas es reintentable e idempotente (`UNIQUE (source, external_id)`). Un bloque que falla se reporta en `/errors` sin deshacer los anteriores.

---

# 9. Seguridad

| Capa | Control |
|------|---------|
| Borde | AWS WAF → Envoy Gateway: JWT del IdP (JWKS), rate limit por tenant y por IP, límites de tamaño |
| Identidad propagada | web-bff intercambia el token del IdP por un **token de contexto** interno (identity-service, 5 min, `aud` por servicio). Ningún servicio confía en cabeceras sin firma |
| Servicio a servicio | mTLS automático (Istio ambient) + `AuthorizationPolicy` (quién puede llamar a qué) + identidad de workload |
| Agente | **Token de capacidad por turno** `{tid, caseId, customerId, perms, exp: 5 min}`; cada servicio comprueba que el recurso pedido pertenece a ese caso. Un error del agente no puede leer otro caso |
| Contacto | Permisos firmados por case-service (§6.4) |
| Kafka | TLS + IAM/SASL; ACL por servicio; PII minimizada (claim check) |
| Datos | RLS por tenant en cada BD; cifrado KMS; *envelope encryption* para PII sensible; secretos con External Secrets |
| Red y cadena de suministro | NetworkPolicies *default-deny*; imágenes firmadas (cosign) y SBOM; escaneo de dependencias y secretos en CI |
| Auditoría | Registro local en el dueño + consolidación sellada en audit-service |

Los controles del agente de la v2 §10 (placeholders, validador de salida, prompt injection, verificación de identidad, límites de costo) se mantienen dentro de agent-service.

## 9.1 Si identity-service falla

| Pieza | Comportamiento |
|---|---|
| Verificación de tokens | Local en cada servicio, con el JWKS en caché (respeta `Cache-Control`, máximo 1 h; se refresca al ver un `kid` desconocido) |
| Token de contexto (web-bff) | Se reutiliza, por sesión y audiencia, hasta 1 min antes de vencer (dura 5 min). Si identity no responde, se usa el vigente hasta que venza |
| Tokens de capacidad del agente | Se verifican localmente. Emitirlos requiere identity: si cae, los turnos esperan con reintentos (se retrasan, no se pierden) |
| Health checks | identity es dependencia blanda: el *readiness* de los demás servicios no depende de él |
| Caída de más de 5 min | La UI ya no puede renovar tokens y muestra un aviso; los mensajes entrantes se siguen guardando. Por eso identity tiene objetivo de 99.95 % (§4.2) |

---

# 10. Resiliencia y degradación

| Falla | Comportamiento | Mecanismo |
|-------|----------------|-----------|
| Kafka no disponible | Los servicios siguen aceptando escrituras; los eventos se acumulan en cada outbox y se publican en orden al volver | Outbox + alerta de *outbox lag* |
| policy-service caído | El agente no decide: el turno pasa a tarea humana; no hay envíos que dependan de reglas de contacto | Fail closed, ≥ 3 réplicas, PDB |
| case-service caído | Sin permisos no hay envíos; los mensajes entrantes se guardan y se procesan después | Fail closed |
| ledger-service caído | Los pagos esperan en Kafka; la UI muestra saldos con `asOf` antiguo | Reanudación por *offset* |
| agent-service o LLM caídos | Mensajes visibles en el inbox; tarea "respuesta pendiente" tras el SLA; modelo de *fallback*; plantillas seguras | Circuit breaker + SLA |
| conversation-service caído | webhook-ingress sigue aceptando; se reprocesa al volver | Ingress desacoplado |
| Mensaje que siempre falla (*poison*) | Va a la DLQ tras N intentos y el resto continúa; según su clase, alerta y pausa protectora (§10.1) | Retry topics + DLQ |
| Evento duplicado o desordenado | Sin efecto doble | Inbox + `aggregateVersion` |
| portfolio-query atrasado | La UI muestra `asOf` y un aviso de frescura | SLO de lag |
| Llega un pago mientras el agente redacta | `ApplyAgentDecision` se rechaza por versión → turno nuevo | `expectedVersion` |
| Disputa justo después de emitir un permiso | Ventana máxima < 60 s; conversation-service también revisa su proyección de pausas | Permiso corto + proyección |
| identity-service caído | Tokens vigentes siguen sirviendo; turnos del agente en espera; aviso en la UI tras 5 min | §9.1 |
| Comando sin respuesta | Vence (`expiresAt`) y se decide de nuevo con contexto fresco | §6.5 |

## 10.1 Mensajes fallidos (DLQ)

Un mensaje que sigue fallando tras sus reintentos va a la DLQ (cola de mensajes fallidos) de su consumidor. La gravedad depende del tipo:

| Clase | Mensajes | Alerta | Primera revisión | Acción automática |
|---|---|---|---|---|
| Crítica | Pagos y ledger (`payment.*`, `ledger.*`), opt-out (`ContactOptedOut`), pausas (`CasePaused`) | Inmediata, a la guardia | ≤ 30 min | Pausa protectora del cliente afectado |
| Alta | Comandos (`*.commands.v1`) y disparadores del agente | DLQ > 0 durante 15 min | ≤ 1 h | — |
| Normal | Proyecciones de lectura, auditoría, analítica | DLQ > 0 durante 15 min | ≤ 4 h hábiles | — |

La pausa protectora existe porque un pago atascado significa seguir cobrándole a quien ya pagó, y un opt-out atascado, escribirle a quien se dio de baja. El chasis publica `ops.events.v1: MessageParked` con las referencias del mensaje (tenant, cliente, contacto), y case-service pausa el caso con motivo `INTERNAL_REVIEW` hasta que el mensaje se reprocesa.

**Runbook por tipo de mensaje:** inspeccionar → reproducir en staging → corregir → republicar desde la DLQ (o desde el inbox crudo de webhook-ingress) → verificar el efecto. La DLQ la atiende el equipo dueño del consumidor.

---

# 11. Proceso API-first

```text
1 Diseñar     PR en contracts/ (OpenAPI 3.1 / AsyncAPI 3.1) + revisión de API con checklist
2 Lint        Spectral (contracts/.spectral.yaml) + Redocly; oasdiff bloquea cambios incompatibles;
              compatibilidad de esquemas en Schema Registry
3 Mock        Prism levanta mocks desde el contrato → frontend y consumidores avanzan en paralelo
4 Generar     TS: tipos + validadores Zod + clientes (orval) · Python: modelos Pydantic
              (datamodel-code-generator) + clientes. Lo generado no se edita a mano.
5 Implementar el servicio implementa el contrato generado (no al revés)
6 Verificar   Schemathesis (pruebas por propiedades contra la implementación) + Pact (consumidor → proveedor);
              oasdiff entre el contrato y el OpenAPI que expone el servicio en ejecución (diferencia = falla)
7 Publicar    portal de APIs (Redocly o Scalar) sin rutas x-internal; changelog; deprecación con
              cabeceras Deprecation/Sunset y 90 días de convivencia
```

**Lineamientos** (aplicados en `contracts/.spectral.yaml`):

- Recursos en plural y kebab-case; propiedades JSON en camelCase; IDs UUID v7.
- El tenant **nunca** va en la ruta ni en el cuerpo: sale del token.
- Dinero como `{ "amount": "48500.00", "currency": "MXN" }`; fechas RFC 3339; vencimientos como `date`.
- Errores RFC 9457 (`application/problem+json`) con `code` estable.
- Paginación por cursor (`cursor`, `limit` ≤ 200) → `{ data, page: { nextCursor } }`.
- `Idempotency-Key` obligatorio en POST públicos con efectos; `If-Match` obligatorio en PATCH y en acciones sobre agregados versionados; `ETag` en GET.
- Acciones de dominio como subrecursos explícitos (`POST /v1/cases/{caseId}/pause`), nunca `PATCH status`.
- Operaciones largas: `202 Accepted` + `Location` del recurso de la operación.
- `/v1` en la ruta; los cambios aditivos no rompen; una versión mayor nueva convive ≥ 90 días.
- Rutas internas bajo `/internal/v1` con `x-internal: true`; el gateway nunca las expone.
- Eventos en pasado, `ce_type = com.receivables.<contexto>.<evento>.v<n>`, un topic por contexto, key = id del agregado.

---

# 12. Plataforma y repositorio

## 12.1 Plataforma

| Capa | Elección | Alternativa |
|------|----------|-------------|
| Orquestación | Amazon EKS (Auto Mode) **[verificar en `mx-central-1`]** | ECS Fargate + Service Connect si el equipo no tiene experiencia en Kubernetes |
| GitOps | Argo CD + un Helm chart común | Flux |
| Malla | Istio ambient (mTLS sin sidecars) | Linkerd (revisar licencia de versiones estables) |
| Autoescalado | HPA (APIs) + KEDA por lag de Kafka (consumidores) | — |
| Gateway | Envoy Gateway (Gateway API) + AWS WAF | Kong, AWS API Gateway |
| Mensajería | Amazon MSK + Schema Registry **[verificar región]** | Confluent Cloud, Redpanda Cloud |
| Bases de datos | RDS PostgreSQL 17, 4 clústeres Multi-AZ, PITR | Aurora PostgreSQL |
| Caché | ElastiCache for Valkey | — |
| Objetos | S3 (+ Object Lock para evidencia) | — |
| Secretos | Secrets Manager + External Secrets Operator + KMS | — |
| IaC | OpenTofu/Terraform | Pulumi (TS) |
| Observabilidad | OpenTelemetry Collector → Grafana Cloud + Sentry + Langfuse | Datadog |
| Flags | OpenFeature + flagd | Unleash |
| Autenticación | WorkOS AuthKit o Clerk | Keycloak autoalojado |

## 12.2 Monorepo

```text
receivables-platform/            pnpm + Nx (TS) · uv workspaces (Python) · CI solo de lo afectado
├── contracts/
│   ├── common/common.yaml       Money, Problem, paginación, cabeceras, seguridad
│   ├── openapi/<servicio>.yaml  contratos síncronos (fuente de verdad)
│   ├── asyncapi/<servicio>.yaml eventos y comandos
│   ├── test-vectors/            casos compartidos TS/Python (dinero, fechas, políticas)
│   └── .spectral.yaml           reglas de diseño de API
├── services/<servicio>/         uno por servicio; hexagonal: api · application · domain · infrastructure
├── edge/                        web-bff · portal-bff · webhook-ingress
├── apps/web/                    Next.js (consume solo web-bff)
├── libs/
│   ├── chassis-ts/  chassis-py/ config, logs, OTel, health, JWT/JWKS, tenant + RLS, outbox, inbox,
│   │                            Kafka (retry/DLQ), circuit breaker, problem+json, idempotencia, sweepers
│   ├── money-ts/  money-py/     verificadas con los mismos test-vectors
│   └── generated/               tipos y clientes generados desde contracts/
├── platform/
│   ├── charts/service/          Deployment, HPA/KEDA, PDB, NetworkPolicy, ServiceMonitor
│   ├── argocd/                  aplicaciones por entorno
│   └── terraform/               VPC, EKS, RDS, MSK, ElastiCache, S3, KMS, IAM
├── tools/create-service/        genera un servicio nuevo con chasis, contrato vacío y pipeline
├── evals/                       dataset dorado y runners del agente
└── docs/adr/
```

Clientes Kafka: `@confluentinc/kafka-javascript` (TS) y `confluent-kafka` (Python), ambos sobre librdkafka.

**Desarrollo local:** `docker compose` con Redpanda (API de Kafka), un Postgres con todas las bases, MinIO, Mailpit y Valkey. Prism no guarda estado, así que el camino crítico corre con servicios reales: webhook-ingress, identity, conversation, case, policy y agent. El resto se sustituye con mocks de Prism generados de los contratos. Tilt (levanta y recarga servicios en local) arranca solo lo necesario. Datos semilla: 1 tenant, 10 clientes, 100 facturas y 5 casos. Las pruebas de contrato (Pact) cubren solo integraciones que existen, empezando por las del camino crítico.

---

# 13. Observabilidad y pruebas

**SLO de punta a punta.** Los flujos asíncronos pasan por colas duraderas: si un servicio cae unos minutos, el resultado llega tarde, pero no se pierde. Por eso se miden por tiempo y no multiplicando disponibilidades:

| Flujo | Objetivo |
|-------|----------|
| Mensaje entrante → respuesta enviada o tarea humana (L2) | p95 ≤ 30 s (incluye *debounce*) · 99.9 % ≤ 15 min · 0 mensajes perdidos |
| Pago confirmado → saldo actualizado | p95 ≤ 60 s · 99.9 % ≤ 10 min |
| Evento → vista de lectura | p95 ≤ 5 s · 99.9 % ≤ 60 s |
| Outbox lag | p99 ≤ 5 s |

Las cadenas síncronas de la UI sí se multiplican. El objetivo del MVP es 99.5 % mensual; con 3 componentes en serie (gateway → web-bff → servicio), cada uno necesita ≥ 99.85 % (0.9985³ ≈ 99.55 %). Las pantallas que componen varios servicios devuelven resultados parciales con aviso, para que una falla no tumbe la página entera. webhook-ingress e identity-service, que están en todos los caminos, tienen objetivo de 99.95 %.

**Paneles:** RED por servicio, lag por grupo de consumo, outbox lag, tamaño de DLQ, permisos rechazados, tasa de `STALE_VERSION`, costo de LLM por tenant. Las trazas cruzan HTTP y Kafka (`traceparent`) y el `correlationId` agrupa un flujo completo.

**Pruebas**

| Nivel | Qué |
|-------|-----|
| Unitarias | Dominio puro: máquinas de estado, políticas, matching, dinero (propiedades con `fast-check` / Hypothesis) |
| Componente | Un servicio con Postgres + Redpanda reales (Testcontainers); los demás con Prism |
| Contrato | Pact HTTP y de mensajes; compatibilidad en Schema Registry; Schemathesis contra la implementación |
| Integración E2E | Staging con sandboxes de WhatsApp y PSP: vencida → mensaje → promesa → pago → conciliación → caso resuelto |
| Caos | Caída de pods, broker no disponible, latencia inyectada con Istio |
| Carga | k6: 100k facturas por tenant, ráfagas de webhooks, 1k conversaciones simultáneas |
| Agente | Evals del dataset dorado y simulador de clientes (v2 §10.7) |

---

# 14. Equipo, fases y costo de la decisión

**Propiedad por equipo** (con 6–8 personas, cada "equipo" son 1–2 personas):

| Equipo | Servicios |
|--------|-----------|
| Cobranza (TS) | customer, invoice, case, policy, agreement, task, dispute (F2), integration (F2) |
| Dinero (TS) | payment, ledger, portal-bff |
| Conversación e IA (TS + Python) | conversation, agent, knowledge (F2), risk (F2), evals |
| Plataforma | gateway, webhook-ingress, identity, document, audit, chasis, infraestructura, observabilidad |
| Experiencia | web, web-bff, portfolio-query |

**Guardias (on-call):** una sola rotación semanal para todo el sistema, con escalamiento al equipo dueño del servicio que alerta. Las alertas y la DLQ se enrutan por dueño (§10.1).

**Fases**

| Fase | Duración orientativa | Contenido |
|------|---------------------|-----------|
| 0 · Plataforma y contratos | 4–6 semanas (en parte en paralelo) | Contratos v0 de los 17 servicios propios, chasis TS/Python, plantilla de servicio, EKS/Kafka/RDS/observabilidad por IaC, CI/CD por servicio, trámite de WhatsApp, design partners |
| 1a · Núcleo | 5–6 semanas | identity, customer, invoice (importaciones), case, policy (reglas de contacto), task, document, audit, portfolio-query v0, web-bff, UI de casos |
| 1b · Conversación y agente | 5–6 semanas | webhook-ingress, conversation (WhatsApp y email), agent (L0/L1), agreement (promesas), detección y pausa de disputas, aprobaciones, evals |
| 1c · Dinero | 4–5 semanas | payment, ledger (conciliación determinista y manual), portal-bff, cumplimiento de promesas, piloto L1 → L2 |
| **MVP 1** | **≈ 20–26 semanas** | Con 6–8 personas, incluida 1 de plataforma/SRE |
| F2 | 8–12 semanas | dispute, knowledge, integration (ERP, estados de cuenta), risk heurístico, planes de pago, simulación de políticas, automatizaciones |
| F3 | — | risk ML, voice-service, sellado y anclaje (audit-service), ClickHouse, autonomía L3 |

**Costo de la decisión** (para planificar, no para reabrirla):

- **Equipo y tiempo:** la v2 estimaba 13–19 semanas con 2–3 personas; esta arquitectura necesita ~20–26 semanas con 6–8, porque añade plataforma, contratos, outbox/inbox y pruebas de contrato por servicio.
- **Infraestructura fija:** ~USD 3.900 al mes en producción antes de tener clientes, más staging (modelo abajo).
- **Mitigaciones incluidas:** chasis y plantilla de servicio, contratos con mocks desde el día 1, 4 clústeres en lugar de 17, un solo Kafka y observabilidad distribuida desde el inicio.

**Modelo de costo de infraestructura** (producción, orden de magnitud)

Precios de lista de referencia; en la región México pueden variar **[verificar con la calculadora de AWS]**. No incluye LLM ni WhatsApp, que dependen del uso.

| Componente | USD/mes | Peso |
|---|---|---|
| EKS (plano de control) | ~75 | 2 % |
| Cómputo (17 servicios × 2 réplicas) | ~1.000 | 25 % |
| RDS: 4 clústeres Multi-AZ (m5.large) | ~1.200 | 31 % |
| Kafka gestionado (3 brokers m5.large) | ~600 | 15 % |
| Valkey | ~100 | 2 % |
| Gateway (NLB + pods) | ~150 | 4 % |
| Observabilidad gestionada | ~500 | 13 % |
| NAT Gateway y transferencia | ~300 | 8 % |
| **Total producción** | **~3.900** | |

- **Staging** suma entre 50 % y 100 % más, según cuánto se reduzca y si se apaga fuera de horario.
- La v3 (monolito modular) quedaría por debajo de ~USD 1.500/mes en producción **[verificar]**: la diferencia ronda los USD 30 mil al año antes del primer cliente.
- **Dónde está el ahorro:** RDS, Kafka y observabilidad suman ~59 %. Pasar en el MVP de 4 clústeres a 2 (`money` aparte y el resto junto) o usar Kafka serverless ahorra más que agrupar procesos, porque el cómputo es ~25 %.
- **Punto de equilibrio:** tenants necesarios = costo fijo mensual ÷ (precio por tenant − costo variable por tenant). Se calcula cuando exista el modelo de precios.

---

# 15. Correcciones

## 15.1 De la v3

| v3 | Cómo queda |
|----|-----------|
| N1 · Serialización por caso | *Lease* por caso en agent-service + `expectedVersion` validado por case-service en `ApplyAgentDecision` |
| N2 · Deduplicación de mensajes | `conversation_db`: `UNIQUE (organization_id, provider, provider_message_id)` |
| N3 · Vistas materializadas sin RLS | portfolio-query-service con tablas normales y RLS |
| N4 · `current_setting` vacío | Función `app.current_org()` en la migración base del chasis |
| N5 · Outbox y cadena de hashes | Outbox por servicio con la regla de versión del agregado; sellado en audit-service |
| N6 · TOCTOU en aprobaciones | Revalidación en agent-service + versión comprobada por case-service (§8.3) |
| N7 · Envío no idempotente | `QUEUED → SENDING → SENT / UNKNOWN` en conversation-service, con `client_ref` |
| N8 · Teléfono compartido | `contact-matches` devuelve 0/1/N; desambiguación en conversation-service |
| N9 · Tres mecanismos asíncronos | Kafka + outbox/inbox por servicio; temporizadores locales (§7.5) |
| N10 · Multimoneda | ledger-service: asignaciones con monto en ambas monedas y tipo de cambio |
| N11 · FKs compuestas | Dentro de cada BD; entre servicios solo IDs + eventos de fusión |
| N12 · Transacción por request | Transacciones cortas por caso de uso en cada servicio |
| N13 · Políticas | `policy_db` con alcance normalizado y una sola versión activa por alcance |
| N15 · Inbox de webhooks | webhook-ingress como servicio propio |
| N16 · *Fairness* entre tenants | Cuotas por tenant en los consumidores; importaciones por bloques con prioridad baja |
| N17 · Consentimiento vigente | conversation-service como dueño del opt-out por canal |
| N18 · Redondeo | `money-ts` y `money-py` con vectores de prueba compartidos |

## 15.2 Revisión externa (v4.1)

| Punto | Qué cambió | Dónde |
|---|---|---|
| Conteo de servicios | 17 servicios propios + gateway = 18 unidades; 22 con F2 | §0, §14 |
| identity como punto único de fallo | JWKS en caché, reutilización del token, dependencia blanda, objetivo 99.95 % | §4.2 S1, §9.1 |
| Versiones de política | Versión fijada por turno y activación programada, en lugar del 412 propuesto | §4.2 S7 |
| Compensaciones | Tipos de paso (reintentable, pivote, compensable), tablas por flujo y orden de acciones dependientes | §8.1, §8.5 |
| Respuesta a comandos | `expiresAt` y rechazo `EXPIRED`; sin reintentos; tabla de timeouts | §6.1, §6.5, contrato AsyncAPI |
| Resolución del tenant | Tabla de rutas sin RLS en cada dueño, en lugar de centralizarla en identity | §7.6, §8.1, §8.2 |
| Opt-out y pausa | Quién verifica qué; `/reachability` en las herramientas del agente | §6.4, §4.3 S15 |
| SLO compuesto | Por tiempo en los flujos asíncronos; multiplicación solo en la UI | §13 |
| Costo | Tabla por componente, staging, palancas de ahorro, fórmula de equilibrio | §14 |
| Desarrollo local | Camino crítico con servicios reales; Prism para el resto; Pact solo en integraciones reales | §12.2 |
| Lease del agente | 90 s, heartbeat de 20 s, `lease_epoch` | §4.3 S15 |
| Retención en Kafka | 90 días; eventos sin datos personales; reconstrucción por exportación | §6.2, §4.4 S18 |
| DLQ | Clases de gravedad, pausa protectora, runbook | §10.1 |
| Guardias | conversation-service con equipo dueño; rotación única con escalamiento | §14 |
| Agrupar despliegues | Decisión abierta, con la variante de ~10 unidades | §16 |

---

# 16. Decisiones abiertas

| Decisión | Propuesta | Cómo decidir |
|----------|-----------|--------------|
| Lenguaje de agent-service | Python | Si el equipo es solo TS, se escribe en TS; el contrato no cambia |
| EKS vs ECS | EKS | Experiencia del equipo con Kubernetes |
| MSK vs Confluent Cloud | El que tenga región México y Schema Registry | **[verificar]** |
| Envoy Gateway vs Kong | Envoy Gateway | Prueba de JWT/JWKS + rate limit por claim de tenant |
| Malla | Istio ambient | Sin experiencia: empezar con NetworkPolicies + tokens de servicio y añadir mTLS en F2 |
| Relay de outbox | Polling en el chasis | Debezium si el volumen lo exige |
| IdP | WorkOS o Clerk | SSO/SCIM y precio por organización |
| Agrupar despliegues | Mantener las 18 unidades | Si el costo o las guardias pesan, aplicar la variante de abajo |
| Clústeres de BD en el MVP | 4 | Pasar a 2 (`money` aparte, el resto junto) si el costo pesa (§14) |

**Variante de agrupación** (10 unidades propias más el gateway), si se decide agrupar:

- **Solas:** webhook-ingress (el SLO más alto), portal-bff (público, sin login), web-bff, identity (punto único de fallo), conversation, money (payment + ledger), read (portfolio-query) y agent (Python).
- **core:** customer, invoice, case, policy, agreement y task.
- **soporte:** document y audit, que son vecinos pesados para case (archivos, antivirus, consumo de todos los eventos).
- **Condición:** los módulos de una unidad se comunican solo por su API interna y por Kafka, nunca importando código entre sí, y CI lo verifica. Si no, separarlos después será muy costoso.
- **Cuándo separar un módulo:** cuando choca con los demás en CPU, memoria, despliegues o escalado. Las métricas de base de datos (transacciones por segundo, filas importadas) no se resuelven separando el proceso, sino moviendo su base a otro clúster.

---

## Siguiente paso

Escribir los contratos v0 (OpenAPI + AsyncAPI) de los 17 servicios propios del MVP 1 siguiendo el ejemplo de `contracts/` (case-service), y levantar mocks con Prism para que frontend y servicios avancen en paralelo desde la Fase 0.
