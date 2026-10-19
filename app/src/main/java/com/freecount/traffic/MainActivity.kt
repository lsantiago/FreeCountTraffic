package com.freecount.traffic

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
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
import com.freecount.traffic.ui.HistoryScreen
import com.freecount.traffic.ui.HomeScreen
import com.freecount.traffic.ui.SessionDetailScreen

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val autotestVideo = intent.getStringExtra("autotest_video")
        val autotestZones = intent.getStringExtra("autotest_zones")
        setContent {
            MaterialTheme(colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme()) {
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
    // 0 = home, 1 = analysis, 2 = history, 3 = session detail
    var screen by rememberSaveable { mutableStateOf(0) }
    var source by rememberSaveable { mutableStateOf(SourceType.CAMERA) }
    var sessionId by rememberSaveable { mutableStateOf(0L) }

    LaunchedEffect(autotestVideo) {
        if (autotestVideo != null) {
            source = SourceType.VIDEO
            screen = 1
            vm.runAutotest(autotestVideo, parseZones(autotestZones))
        }
    }

    BackHandler(enabled = screen != 0) {
        when (screen) {
            1 -> { if (vm.running) vm.stop(); screen = 0 }
            3 -> screen = 2
            else -> screen = 0
        }
    }

    when (screen) {
        0 -> HomeScreen(onSource = { source = it; screen = 1 }, onHistory = { screen = 2 })
        1 -> AnalysisScreen(vm, source, onBack = { screen = 0 })
        2 -> HistoryScreen(vm, onBack = { screen = 0 }, onOpen = { sessionId = it; screen = 3 })
        else -> SessionDetailScreen(vm, sessionId, onBack = { screen = 2 })
    }
}
