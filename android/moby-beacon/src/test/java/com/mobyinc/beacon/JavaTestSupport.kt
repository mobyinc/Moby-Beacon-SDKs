package com.mobyinc.beacon

import com.mobyinc.beacon.support.FixedRandom
import com.mobyinc.beacon.support.MemoryQueueStorage
import com.mobyinc.beacon.support.MockHttpClient
import com.mobyinc.beacon.support.TestScheduler
import com.mobyinc.beacon.support.eventsOf
import com.mobyinc.beacon.support.jsonToMap

/**
 * Lets a Java test start a beacon over the test doubles without touching the
 * module's `internal` seams, which Java cannot name cleanly.
 */
class JavaTestSupport {
    private val scheduler = TestScheduler()
    private val storage = MemoryQueueStorage()
    private val client = MockHttpClient()
    private val beacons = ArrayList<MobyBeacon>()

    /** Starts a beacon for [config] over in-memory storage and the mock client, run until idle. */
    fun start(config: MobyBeaconConfig): MobyBeacon {
        val beacon = MobyBeacon.start(
            config,
            EventStore(storage, config.maxQueueSize) { scheduler.post(it) },
            client.transport(),
            scheduler,
            null,
            FixedRandom(0.0),
        )
        beacons.add(beacon)
        scheduler.runUntilIdle()
        return beacon
    }

    fun runUntilIdle() {
        scheduler.runUntilIdle()
    }

    fun advanceBy(deltaMs: Long) {
        scheduler.advanceBy(deltaMs)
    }

    fun requestCount(): Int = client.requests.size

    /** The events of request [index], each as a plain map. */
    fun sentEvents(index: Int): List<Map<String, Any?>> =
        eventsOf(client.requests[index].body).map { jsonToMap(it) }

    fun storedContents(): String? = storage.contents

    fun tearDown() {
        for (beacon in beacons) beacon.dispose()
        beacons.clear()
        scheduler.releaseResponses()
        scheduler.runUntilIdle()
        MobyBeacon.resetLiveForTesting()
    }
}
