package com.freecount.traffic

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.viewmodel.compose.viewModel
import com.freecount.traffic.core.RectN
import com.freecount.traffic.core.Zone
import com.freecount.traffic.source.SourceType
import com.freecount.traffic.ui.AnalysisScreen
import com.freecount.traffic.ui.AnalysisViewModel
import com.freecount.traffic.ui.GraphScreen
import com.freecount.traffic.ui.HistoryScreen
import com.freecount.traffic.ui.HomeScreen
import com.freecount.traffic.ui.SessionDetailScreen
import com.freecount.traffic.ui.TrafficTheme
import com.freecount.traffic.ui.ValidationScreen

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val autotestVideo = intent.getStringExtra("autotest_video")
        val autotestZones = intent.getStringExtra("autotest_zones")
        setContent {
            TrafficTheme {
                Surface(Modifier.fillMaxSize()) { AppRoot(autotestVideo, autotestZones) }
            }
        }
    }
}

/** "l,t,r,b[,lengthMeters];l,t,r,b..." in normalized coordinates. */
private fun parseZones(spec: String?): List<Zone> = spec.orEmpty().split(';').filter { it.isNotBlank() }.mapIndexedNotNull { i, s ->
    val p = s.split(',').mapNotNull { it.trim().toFloatOrNull() }
    if (p.size < 4) null else Zone(i + 1, "Zone ${i + 1}", RectN(p[0], p[1], p[2], p[3]), p.getOrNull(4))
}

@Composable
private fun AppRoot(autotestVideo: String? = null, autotestZones: String? = null) {
    val vm: AnalysisViewModel = viewModel()
    // 0 = home, 1 = analysis, 2 = history, 3 = session detail, 4 = graph, 5 = validate detections
    var screen by rememberSaveable { mutableStateOf(0) }
    var source by rememberSaveable { mutableStateOf(SourceType.CAMERA) }
    var sessionId by rememberSaveable { mutableStateOf(0L) }
    var zoneId by rememberSaveable { mutableStateOf(0) }
    // where Back from the session results goes: 1 = the analysis screen it was opened from, 2 = history
    var detailBack by rememberSaveable { mutableStateOf(2) }

    LaunchedEffect(autotestVideo) {
        if (autotestVideo != null) {
            source = SourceType.VIDEO
            screen = 1
            vm.runAutotest(autotestVideo, parseZones(autotestZones))
        }
    }
    // CI tour after the autotest: results, graph, validation of the first box
    LaunchedEffect(vm.autotestStage) {
        val id = vm.lastSessionId ?: return@LaunchedEffect
        when (vm.autotestStage) {
            1 -> { sessionId = id; screen = 3 }
            2 -> screen = 4
            4 -> { zoneId = vm.zones.value.firstOrNull()?.id ?: 0; screen = 5 }
        }
    }

    BackHandler(enabled = screen != 0) {
        when (screen) {
            1 -> { vm.leaveAnalysis(); screen = 0 }
            3 -> screen = detailBack
            4, 5 -> screen = 3
            else -> screen = 0
        }
    }

    when (screen) {
        0 -> HomeScreen(onSource = { source = it; screen = 1 }, onHistory = { screen = 2 })
        1 -> AnalysisScreen(
            vm, source,
            onBack = { screen = 0 },
            onResults = { sessionId = it; detailBack = 1; screen = 3 },
            autotest = autotestVideo != null,
        )
        2 -> HistoryScreen(vm, onBack = { screen = 0 }, onOpen = { sessionId = it; detailBack = 2; screen = 3 })
        3 -> SessionDetailScreen(
            vm, sessionId,
            onBack = { screen = detailBack },
            onGraph = { screen = 4 },
            onValidate = { zoneId = it; screen = 5 },
        )
        4 -> GraphScreen(vm, sessionId, onBack = { screen = 3 })
        else -> ValidationScreen(vm, sessionId, zoneId, onBack = { screen = 3 })
    }
}
