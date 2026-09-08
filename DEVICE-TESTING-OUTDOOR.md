# Manual device testing — outdoor activity recording

Simulator GPS can be faked (Xcode → Debug → Simulate Location, or a GPX
file), but background location reliability and the actual HealthKit write
need a real device and a real walk.

1. Grant "Always" location access when prompted on first "Start Run."
2. Start a Run, lock the phone, walk for at least 2 minutes.
3. Unlock — the live screen should show a distance greater than zero and a
   map trace with more than one point (confirms points accumulated while
   locked, not just while foregrounded).
4. Tap Finish. The review screen should show the same route with the full
   path visible on the map.
5. Open the Health app → Browse → Activity → Workouts. The just-finished
   Run should appear with a route. Tap into it and confirm the map matches
   what LIFT's review screen showed.
6. Force-quit LIFT and relaunch. The activity should still be in the
   Outdoor tab's history, with its route intact (confirms `routePointsData`
   persisted correctly, not just held in memory).
7. Repeat once for Hike, confirming it appears in Health as a Hiking
   workout, not Running.
