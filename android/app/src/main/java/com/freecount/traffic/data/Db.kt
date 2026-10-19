package com.freecount.traffic.data

import android.content.Context
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Index
import androidx.room.Insert
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.Transaction
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import com.freecount.traffic.core.CountEvent
import com.freecount.traffic.core.VehicleClass
import kotlinx.coroutines.flow.Flow

@Entity
data class SessionEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val name: String,
    val source: String,
    val startedAt: Long,
    /** Analysed span (video time for files, wall time for live sources). */
    val durationMs: Long,
    val latitude: Double?,
    val longitude: Double?,
    val zonesJson: String,
    /** Wall-clock time (epoch ms) of the first analysed frame, used to label intervals; null when unknown. */
    val clockStart: Long? = null,
)

@Entity(indices = [Index("sessionId")])
data class RecordEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val sessionId: Long,
    val zoneId: Int,
    val zoneName: String,
    val trackId: Int,
    val vehicleClass: String,
    val direction: String,
    val speedKmh: Float?,
    val timeMs: Long,
    val score: Float? = null,
) {
    fun toEvent() = CountEvent(
        zoneId, zoneName, trackId,
        runCatching { VehicleClass.valueOf(vehicleClass) }.getOrDefault(VehicleClass.CAR),
        direction, speedKmh, timeMs, score,
    )

    companion object {
        fun from(sessionId: Long, e: CountEvent) =
            RecordEntity(0, sessionId, e.zoneId, e.zoneName, e.trackId, e.cls.name, e.direction, e.speedKmh, e.timeMs, e.score)
    }
}

@Dao
abstract class SessionDao {
    @Insert abstract suspend fun insertSession(s: SessionEntity): Long
    @Insert abstract suspend fun insertRecords(r: List<RecordEntity>)

    @Query("SELECT * FROM SessionEntity ORDER BY startedAt DESC")
    abstract fun observeSessions(): Flow<List<SessionEntity>>

    @Query("SELECT * FROM SessionEntity WHERE id = :id")
    abstract suspend fun session(id: Long): SessionEntity?

    @Query("SELECT * FROM RecordEntity WHERE sessionId = :id ORDER BY timeMs")
    abstract suspend fun records(id: Long): List<RecordEntity>

    @Query("DELETE FROM SessionEntity WHERE id = :id")
    abstract suspend fun deleteSessionRow(id: Long)

    @Query("DELETE FROM RecordEntity WHERE sessionId = :id")
    abstract suspend fun deleteRecords(id: Long)

    @Query("UPDATE SessionEntity SET name = :name WHERE id = :id")
    abstract suspend fun rename(id: Long, name: String)

    /** Validation: remove a wrong detection from one box. */
    @Query("DELETE FROM RecordEntity WHERE sessionId = :id AND zoneId = :zoneId AND trackId = :trackId")
    abstract suspend fun deleteRecord(id: Long, zoneId: Int, trackId: Int)

    /** Validation: fix the class of a vehicle (in every box it crossed). */
    @Query("UPDATE RecordEntity SET vehicleClass = :cls WHERE sessionId = :id AND trackId = :trackId")
    abstract suspend fun reclassify(id: Long, trackId: Int, cls: String)

    @Transaction
    open suspend fun save(session: SessionEntity, events: List<CountEvent>): Long {
        val id = insertSession(session)
        insertRecords(events.map { RecordEntity.from(id, it) })
        return id
    }

    @Transaction
    open suspend fun delete(id: Long) {
        deleteRecords(id)
        deleteSessionRow(id)
    }
}

@Database(entities = [SessionEntity::class, RecordEntity::class], version = 2, exportSchema = false)
abstract class AppDb : RoomDatabase() {
    abstract fun sessions(): SessionDao

    companion object {
        @Volatile private var instance: AppDb? = null

        /** v2: interval clock start per session and detection confidence per vehicle. */
        private val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE SessionEntity ADD COLUMN clockStart INTEGER")
                db.execSQL("ALTER TABLE RecordEntity ADD COLUMN score REAL")
            }
        }

        fun get(context: Context): AppDb = instance ?: synchronized(this) {
            instance ?: Room.databaseBuilder(context.applicationContext, AppDb::class.java, "traffic.db")
                .addMigrations(MIGRATION_1_2)
                .build().also { instance = it }
        }
    }
}
