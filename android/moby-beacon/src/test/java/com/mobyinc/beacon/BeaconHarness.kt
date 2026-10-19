package com.mobyinc.beacon

import com.mobyinc.beacon.support.FixedRandom
import com.mobyinc.beacon.support.HttpRequest
import com.mobyinc.beacon.support.HttpResponse
import com.mobyinc.beacon.support.MemoryQueueStorage
import com.mobyinc.beacon.support.MockHttpClient
import com.mobyinc.beacon.support.TestScheduler
import com.mobyinc.beacon.support.accepted
import com.mobyinc.beacon.support.actionsOf
import com.mobyinc.beacon.support.emptyResponse
import com.mobyinc.beacon.support.eventsOf
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Before
import java.net.ConnectException
import kotlin.random.Random

/**
 * Port of the iOS `BeaconHarness` and the `main()` preamble of
 * `moby_beacon_test.dart`: a per-test virtual-time scheduler, in-memory
 * storage and a mock HTTP client that records every request. Every beacon
 * started through [start] is disposed in [tearDownHarness].
 */
abstract class BeaconHarness {
    internal lateinit var scheduler: TestScheduler
    lateinit var storage: MemoryQueueStorage
    lateinit var client: MockHttpClient

    /** Every error reported to the default `onError`, in order. */
    val errors = ArrayList<MobyBeaconError>()

    /** Answers each request; replace it to fail or script sends. */
    var respond: (HttpRequest) -> HttpResponse = { accepted() }

    private val beacons = ArrayList<MobyBeacon>()

    /** The `events` array of each request, in order. */
    val requests: List<List<JSONObject>> get() = client.requests.map { eventsOf(it.body) }

    /** The body size of each request, in bytes. */
    val requestBytes: List<Int> get() = client.requests.map { it.body.size }

    @Before
    fun setUpHarness() {
        scheduler = TestScheduler()
        storage = MemoryQueueStorage()
        errors.clear()
        respond = { accepted() }
        client = MockHttpClient()
        client.handler = { respond(it) }
    }

    @After
    fun tearDownHarness() {
        for (beacon in beacons) beacon.dispose()
        beacons.clear()
        scheduler.releaseResponses()
        scheduler.runUntilIdle()
        MobyBeacon.resetLiveForTesting()
    }

    /**
     * Flutter's `create`: a beacon over [storage] and the mock client, with no
     * jitter, not yet run.
     */
    internal fun makeBeacon(
        batchSize: Int = 10,
        maxQueueSize: Int = 100,
        onError: MobyBeaconErrorHandler? = null,
        transport: EventTransport? = null,
        lifecycle: LifecycleSource? = null,
        userId: String = "user-1",
        random: Random = FixedRandom(0.0),
    ): MobyBeacon {
        val config = MobyBeaconConfig.Builder("https://beacon.test", "key-123", userId)
            .batchSize(batchSize)
            .maxQueueSize(maxQueueSize)
            .onError(onError ?: MobyBeaconErrorHandler { errors.add(it) })
            .build()
        return MobyBeacon.start(
            config,
            EventStore(storage, maxQueueSize) { scheduler.post(it) },
            transport ?: client.transport(),
            scheduler,
            lifecycle,
            random,
        )
    }

    /** [makeBeacon], run until idle, and disposed in [tearDownHarness]. */
    internal fun start(
        batchSize: Int = 10,
        maxQueueSize: Int = 100,
        onError: MobyBeaconErrorHandler? = null,
        transport: EventTransport? = null,
        lifecycle: LifecycleSource? = null,
        userId: String = "user-1",
        random: Random = FixedRandom(0.0),
    ): MobyBeacon {
        val beacon = makeBeacon(batchSize, maxQueueSize, onError, transport, lifecycle, userId, random)
        scheduler.runUntilIdle()
        beacons.add(beacon)
        return beacon
    }

    /** Registers a beacon made with [makeBeacon] for disposal in tear-down. */
    fun disposeLater(beacon: MobyBeacon) {
        beacons.add(beacon)
    }

    fun sentActions(requestIndex: Int): List<String> {
        val sent = requests
        if (requestIndex >= sent.size) {
            fail("only ${sent.size} request(s) sent")
            return emptyList()
        }
        return actionsOf(sent[requestIndex])
    }

    /** Dart's `errors.single`. */
    fun singleError(): MobyBeaconError {
        assertEquals("expected exactly one error: $errors", 1, errors.size)
        return errors[0]
    }

    /** Every send fails before a response arrives. */
    fun offline() {
        respond = { throw ConnectException("Connection refused") }
    }

    /** Every send is answered with [status] and no body. */
    fun answer(status: Int, headers: Map<String, String> = emptyMap()) {
        respond = { emptyResponse(status, headers) }
    }

    fun acceptAll() {
        respond = { accepted() }
    }

    /** Requests are made but their results stay in flight until [release]. */
    fun hold() {
        scheduler.holdResponses = true
    }

    fun release() {
        scheduler.releaseResponses()
    }
}
