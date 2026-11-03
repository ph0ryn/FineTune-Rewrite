-------------------------- MODULE CallbackSlotModel --------------------------
EXTENDS Integers, FiniteSets

CONSTANTS Readers, CheckCookie
VARIABLES pc, token, captured, touched, count, active, body, alive, writer, staleClose
vars == <<pc, token, captured, touched, count, active, body, alive, writer, staleClose>>

Counted == {"counted", "checked", "loaded", "used", "rejected"}
Holding == {"loaded", "used"}

Init ==
    /\ pc = [r \in Readers |-> "idle"]
    /\ token = [r \in Readers |-> 0]
    /\ captured = [r \in Readers |-> 0]
    /\ touched = [r \in Readers |-> 0]
    /\ count = 0
    /\ active = 1
    /\ body = 1
    /\ alive = {1}
    /\ writer = "open1"
    /\ staleClose = FALSE

Begin(r, c) ==
    /\ pc[r] = "idle"
    /\ (c = 1 \/ writer = "open2")
    /\ pc' = [pc EXCEPT ![r] = "preentry"]
    /\ token' = [token EXCEPT ![r] = c]
    /\ UNCHANGED <<captured, touched, count, active, body, alive, writer, staleClose>>

Increment(r) ==
    /\ pc[r] = "preentry"
    /\ pc' = [pc EXCEPT ![r] = "counted"]
    /\ count' = count + 1
    /\ UNCHANGED <<token, captured, touched, active, body, alive, writer, staleClose>>

Validate(r) ==
    /\ pc[r] = "counted"
    /\ pc' = [pc EXCEPT ![r] = IF ~CheckCookie \/ active = token[r]
                                 THEN "checked" ELSE "rejected"]
    /\ UNCHANGED <<token, captured, touched, count, active, body, alive, writer, staleClose>>

Load(r) ==
    /\ pc[r] = "checked"
    /\ pc' = [pc EXCEPT ![r] = "loaded"]
    /\ captured' = [captured EXCEPT ![r] = body]
    /\ UNCHANGED <<token, touched, count, active, body, alive, writer, staleClose>>

Use(r) ==
    /\ pc[r] = "loaded"
    /\ pc' = [pc EXCEPT ![r] = "used"]
    /\ touched' = [touched EXCEPT ![r] = captured[r]]
    /\ UNCHANGED <<token, captured, count, active, body, alive, writer, staleClose>>

Leave(r) ==
    /\ pc[r] \in {"used", "rejected"}
    /\ pc' = [pc EXCEPT ![r] = "done"]
    /\ count' = count - 1
    /\ UNCHANGED <<token, captured, touched, active, body, alive, writer, staleClose>>

CloseOld ==
    /\ writer = "open1"
    /\ writer' = "closed1"
    /\ active' = 0
    /\ UNCHANGED <<pc, token, captured, touched, count, body, alive, staleClose>>

ReclaimOld ==
    /\ writer = "closed1"
    /\ count = 0
    /\ writer' = "reclaimed1"
    /\ body' = 0
    /\ alive' = alive \ {1}
    /\ UNCHANGED <<pc, token, captured, touched, count, active, staleClose>>

InstallNew ==
    /\ writer = "reclaimed1"
    /\ writer' = "installed2"
    /\ body' = 2
    /\ alive' = alive \cup {2}
    /\ UNCHANGED <<pc, token, captured, touched, count, active, staleClose>>

PublishNew ==
    /\ writer = "installed2"
    /\ writer' = "open2"
    /\ active' = 2
    /\ UNCHANGED <<pc, token, captured, touched, count, body, alive, staleClose>>

CancelOldAgain ==
    /\ writer = "open2"
    /\ ~staleClose
    /\ staleClose' = TRUE
    \* compare_exchange(expected=old cookie), not unconditional store zero
    /\ active' = IF active = 1 THEN 0 ELSE active
    /\ UNCHANGED <<pc, token, captured, touched, count, body, alive, writer>>

Next ==
    \/ \E r \in Readers, c \in {1, 2}: Begin(r, c)
    \/ \E r \in Readers: Increment(r) \/ Validate(r) \/ Load(r) \/ Use(r) \/ Leave(r)
    \/ CloseOld \/ ReclaimOld \/ InstallNew \/ PublishNew \/ CancelOldAgain

CounterExact == count = Cardinality({r \in Readers: pc[r] \in Counted})
BorrowAlive == \A r \in Readers: pc[r] \in Holding => captured[r] \in alive
CookieIsolated == \A r \in Readers: pc[r] \in Holding => captured[r] = token[r]
TouchesCorrect == \A r \in Readers: touched[r] # 0 => touched[r] = token[r]
StaleCancelIsolated == writer = "open2" => active = 2

Spec == Init /\ [][Next]_vars
=============================================================================
