---------------------------- MODULE TarshareStore ----------------------------
(***************************************************************************)
(* The smallest model of the tarshare store protocol in                    *)
(* design/distributed-store.md: one server, clients that look a key up,    *)
(* compute, upload and publish, single-flight leases bound to a client's   *)
(* connection, put-if-absent publication, owner pins, and collection that  *)
(* runs while clients are active.                                          *)
(*                                                                         *)
(* Results are nondeterministic: two computations of the same key may      *)
(* produce different objects. That is what makes "every consumer sees one *)
(* result" a property to check rather than a tautology.                    *)
(*                                                                         *)
(* Each server-side step (Claim, PutEnd, Publish, GC, a connection drop)   *)
(* is atomic because the server handles one request at a time.            *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Clients,   \* client processes; each is also its own retention owner
          Keys,      \* computation keys
          Objects,   \* possible result objects (content ids)
          None,      \* a model value distinct from all of the above
          MaxBlips,  \* bound on connection drops and server restarts
          MaxGC      \* bound on collections

VARIABLES
  actions,    \* server: key -> published object, or None
  committed,  \* server: set of complete, verified objects
  staged,     \* server: client -> object being uploaded on its connection, or None
  lease,      \* server: key -> client holding the single-flight lease, or None
  pins,       \* server: set of <<owner, key>>
  conn,       \* client -> its connection is up
  pc,         \* client -> program counter
  key,        \* client -> the key it wants
  result,     \* client -> object it computed, or None
  want,       \* client -> object it was told to download, or None
  delivered,  \* client -> object it returned to its caller, or None
  computes,   \* ghost: key -> computations started
  drops,      \* ghost: key -> leases dropped unpublished, plus actions collected
  blips,      \* bound counter
  gcs         \* bound counter

vars == <<actions, committed, staged, lease, pins, conn, pc, key, result, want,
          delivered, computes, drops, blips, gcs>>

States == {"idle", "waiting", "computing", "computed", "uploading", "uploaded",
           "fetching", "done", "crashed"}
Finished == {"done", "crashed"}
Opt(S) == S \cup {None}

TypeOK ==
  /\ actions \in [Keys -> Opt(Objects)]
  /\ committed \subseteq Objects
  /\ staged \in [Clients -> Opt(Objects)]
  /\ lease \in [Keys -> Opt(Clients)]
  /\ pins \subseteq Clients \X Keys
  /\ conn \in [Clients -> BOOLEAN]
  /\ pc \in [Clients -> States]
  /\ key \in [Clients -> Keys]
  /\ result \in [Clients -> Opt(Objects)]
  /\ want \in [Clients -> Opt(Objects)]
  /\ delivered \in [Clients -> Opt(Objects)]

Init ==
  /\ actions = [k \in Keys |-> None]
  /\ committed = {}
  /\ staged = [c \in Clients |-> None]
  /\ lease = [k \in Keys |-> None]
  /\ pins = {}
  /\ conn = [c \in Clients |-> TRUE]
  /\ pc = [c \in Clients |-> "idle"]
  /\ key \in [Clients -> Keys]
  /\ result = [c \in Clients |-> None]
  /\ want = [c \in Clients |-> None]
  /\ delivered = [c \in Clients |-> None]
  /\ computes = [k \in Keys |-> 0]
  /\ drops = [k \in Keys |-> 0]
  /\ blips = 0
  /\ gcs = 0

\* Losing a connection, by crash, network blip or server restart, drops
\* that client's leases and its unfinished upload. Nothing else.
DropLeasesOf(S) == [k \in Keys |-> IF lease[k] \in S THEN None ELSE lease[k]]
DroppedCount(S) == [k \in Keys |-> drops[k] + IF lease[k] \in S THEN 1 ELSE 0]

-----------------------------------------------------------------------------
\* CLAIM key format owner. A hit pins in the same step; a miss takes the
\* lease if it is free; otherwise the client is told BUSY and polls again.
Claim(c) ==
  LET k == key[c] IN
  /\ pc[c] \in {"idle", "waiting"} /\ conn[c]
  /\ IF actions[k] # None
       THEN /\ pins' = pins \cup {<<c, k>>}
            /\ want' = [want EXCEPT ![c] = actions[k]]
            /\ pc' = [pc EXCEPT ![c] = "fetching"]
            /\ UNCHANGED lease
       ELSE IF lease[k] = None
         THEN /\ lease' = [lease EXCEPT ![k] = c]
              /\ pc' = [pc EXCEPT ![c] = "computing"]
              /\ UNCHANGED <<pins, want>>
         ELSE /\ pc' = [pc EXCEPT ![c] = "waiting"]
              /\ UNCHANGED <<pins, want, lease>>
  /\ UNCHANGED <<actions, committed, staged, conn, key, result, delivered,
                 computes, drops, blips, gcs>>

\* The client evaluates the command. It needs no connection and sends no
\* heartbeat; its lease lives as long as its connection does.
Compute(c) ==
  /\ pc[c] = "computing"
  /\ \E o \in Objects : result' = [result EXCEPT ![c] = o]
  /\ computes' = [computes EXCEPT ![key[c]] = @ + 1]
  /\ pc' = [pc EXCEPT ![c] = "computed"]
  /\ UNCHANGED <<actions, committed, staged, lease, pins, conn, key, want,
                 delivered, drops, blips, gcs>>

\* HAVE, then PUT_BEGIN when the server lacks the object.
Upload(c) ==
  /\ pc[c] = "computed" /\ conn[c]
  /\ IF result[c] \in committed
       THEN /\ pc' = [pc EXCEPT ![c] = "uploaded"]
            /\ UNCHANGED staged
       ELSE /\ staged' = [staged EXCEPT ![c] = result[c]]
            /\ pc' = [pc EXCEPT ![c] = "uploading"]
  /\ UNCHANGED <<actions, committed, lease, pins, conn, key, result, want,
                 delivered, computes, drops, blips, gcs>>

\* PUT_END: verify and commit. If the connection dropped meanwhile, the stage
\* is gone and the client starts the upload again.
PutEnd(c) ==
  /\ pc[c] = "uploading" /\ conn[c]
  /\ IF staged[c] = None
       THEN /\ pc' = [pc EXCEPT ![c] = "computed"]
            /\ UNCHANGED <<committed, staged>>
       ELSE /\ committed' = committed \cup {staged[c]}
            /\ staged' = [staged EXCEPT ![c] = None]
            /\ pc' = [pc EXCEPT ![c] = "uploaded"]
  /\ UNCHANGED <<actions, lease, pins, conn, key, result, want, delivered,
                 computes, drops, blips, gcs>>

\* PUBLISH key object format owner. Refused unless the object is committed
\* (a collection may have removed it: upload again). Put-if-absent: an
\* earlier winner is kept and the caller must deliver the winner.
Publish(c) ==
  LET k == key[c]
      winner == IF actions[k] = None THEN result[c] ELSE actions[k]
  IN
  /\ pc[c] = "uploaded" /\ conn[c]
  /\ IF result[c] \notin committed
       THEN /\ pc' = [pc EXCEPT ![c] = "computed"]
            /\ UNCHANGED <<actions, lease, pins, want, delivered>>
       ELSE /\ actions' = [actions EXCEPT ![k] = winner]
            /\ pins' = pins \cup {<<c, k>>}
            /\ lease' = IF lease[k] = c THEN [lease EXCEPT ![k] = None] ELSE lease
            /\ IF winner = result[c]
                 THEN /\ delivered' = [delivered EXCEPT ![c] = winner]
                      /\ pc' = [pc EXCEPT ![c] = "done"]
                      /\ UNCHANGED want
                 ELSE /\ want' = [want EXCEPT ![c] = winner]
                      /\ pc' = [pc EXCEPT ![c] = "fetching"]
                      /\ UNCHANGED delivered
  /\ UNCHANGED <<committed, staged, conn, key, result, computes, drops, blips, gcs>>

\* MANIFEST and GET_CHUNK. FetchSafe below asserts the object is still there.
Fetch(c) ==
  /\ pc[c] = "fetching" /\ conn[c]
  /\ delivered' = [delivered EXCEPT ![c] = want[c]]
  /\ pc' = [pc EXCEPT ![c] = "done"]
  /\ UNCHANGED <<actions, committed, staged, lease, pins, conn, key, result,
                 want, computes, drops, blips, gcs>>

-----------------------------------------------------------------------------
\* Failures and maintenance.

Crash(c) ==
  /\ pc[c] \notin Finished
  /\ pc' = [pc EXCEPT ![c] = "crashed"]
  /\ conn' = [conn EXCEPT ![c] = FALSE]
  /\ lease' = DropLeasesOf({c})
  /\ drops' = DroppedCount({c})
  /\ staged' = [staged EXCEPT ![c] = None]
  /\ UNCHANGED <<actions, committed, pins, key, result, want, delivered,
                 computes, blips, gcs>>

\* The connection drops while the client keeps running: it loses its lease
\* and may go on computing without one.
Blip(c) ==
  /\ conn[c] /\ pc[c] \notin Finished /\ blips < MaxBlips
  /\ conn' = [conn EXCEPT ![c] = FALSE]
  /\ lease' = DropLeasesOf({c})
  /\ drops' = DroppedCount({c})
  /\ staged' = [staged EXCEPT ![c] = None]
  /\ blips' = blips + 1
  /\ UNCHANGED <<actions, committed, pins, pc, key, result, want, delivered,
                 computes, gcs>>

\* The server restarts: disk state (actions, objects, pins) survives;
\* in-memory leases and uploads do not, and every connection drops.
ServerRestart ==
  /\ blips < MaxBlips
  /\ conn' = [c \in Clients |-> FALSE]
  /\ lease' = DropLeasesOf(Clients)
  /\ drops' = DroppedCount(Clients)
  /\ staged' = [c \in Clients |-> None]
  /\ blips' = blips + 1
  /\ UNCHANGED <<actions, committed, pins, pc, key, result, want, delivered,
                 computes, gcs>>

Reconnect(c) ==
  /\ ~conn[c] /\ pc[c] # "crashed"
  /\ conn' = [conn EXCEPT ![c] = TRUE]
  /\ UNCHANGED <<actions, committed, staged, lease, pins, pc, key, result, want,
                 delivered, computes, drops, blips, gcs>>

\* RELEASE owner, quiescent = TRUE: the operator asserts the owner is finished.
Release(c) ==
  /\ pc[c] \in Finished
  /\ \E p \in pins : p[1] = c
  /\ pins' = {p \in pins : p[1] # c}
  /\ UNCHANGED <<actions, committed, staged, lease, conn, pc, key, result, want,
                 delivered, computes, drops, blips, gcs>>

\* GC, with no quiescence precondition: unpinned actions go, then every
\* object no remaining action reaches. Uploads in progress are not committed
\* objects and are untouched.
GC ==
  LET kept == {k \in Keys : \E p \in pins : p[2] = k}
      next == [k \in Keys |-> IF k \in kept THEN actions[k] ELSE None]
  IN
  /\ gcs < MaxGC
  /\ actions' = next
  /\ committed' = {next[k] : k \in Keys} \ {None}
  /\ drops' = [k \in Keys |->
                 drops[k] + IF actions[k] # None /\ k \notin kept THEN 1 ELSE 0]
  /\ gcs' = gcs + 1
  /\ UNCHANGED <<staged, lease, pins, conn, pc, key, result, want, delivered,
                 computes, blips>>

Terminated == \A c \in Clients : pc[c] \in Finished

Next ==
  \/ \E c \in Clients :
       \/ Claim(c) \/ Compute(c) \/ Upload(c) \/ PutEnd(c) \/ Publish(c)
       \/ Fetch(c) \/ Crash(c) \/ Blip(c) \/ Reconnect(c) \/ Release(c)
  \/ ServerRestart
  \/ GC
  \/ (Terminated /\ UNCHANGED vars)

Fairness ==
  \A c \in Clients :
    /\ WF_vars(Claim(c)) /\ WF_vars(Compute(c)) /\ WF_vars(Upload(c))
    /\ WF_vars(PutEnd(c)) /\ WF_vars(Publish(c)) /\ WF_vars(Fetch(c))
    /\ WF_vars(Reconnect(c))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
\* Safety.

\* An action becomes visible only with a complete object behind it, and
\* collection never leaves an action pointing at nothing.
ActionsHaveObjects == \A k \in Keys : actions[k] # None => actions[k] \in committed

\* Pins keep their actions: nothing pinned is ever collected.
PinsHold == \A p \in pins : actions[p[2]] # None

\* A client sent to download an object finds it there: the pin taken with
\* the lookup protects the window between "found it" and "fetched it".
FetchSafe == \A c \in Clients : pc[c] = "fetching" => want[c] \in committed

\* One result per key: while a consumer's pin stands, the action is exactly
\* what that consumer delivered, so all pinned consumers of a key agree,
\* even though computations may produce different objects.
OneResult ==
  \A c \in Clients :
    (delivered[c] # None /\ <<c, key[c]>> \in pins) => delivered[c] = actions[key[c]]

\* Leases are bound to live connections.
LeaseOnLiveConnection ==
  \A k \in Keys : lease[k] # None => conn[lease[k]] /\ pc[lease[k]] # "crashed"

\* Single flight: a key is computed again only after a lease was lost
\* unpublished or its action was collected.
SingleFlight == \A k \in Keys : computes[k] <= 1 + drops[k]

Safety == TypeOK /\ ActionsHaveObjects /\ PinsHold /\ FetchSafe /\ OneResult
          /\ LeaseOnLiveConnection /\ SingleFlight

\* Liveness: every client that does not crash returns a result.
Completes == <>Terminated
=============================================================================
