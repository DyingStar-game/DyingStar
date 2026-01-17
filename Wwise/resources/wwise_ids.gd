class_name AK

class EVENTS:

	const LOOPHAMMERDRILL : int = 3807098640
	const STOPHAMMERDRILL : int = 459691002
	const PLAYALL : int = 1820532916
	const STOPALL : int = 3086540886
	const PLAY_PLAYER_FOOTSTEP : int = 1724675634
	const VEHICULE_START : int = 1019570671
	const VEHICULE_STOP : int = 2869434869
	const VEHICULE_ACCELERATION : int = 2950849521
	const VEHICULE_DECELERATION : int = 1280827832
	const PLAY_BGM : int = 3126765036
	const START_WIND : int = 1863965372
	const STOP_BGM : int = 1073466678
	const TEST_BIP_100MS : int = 2818994661
	const TEST_BIP_LONG : int = 4043459374

class STATES:

	class AREASTATE:
		const GROUP : int = 2064552269
	
		class STATE:
			const NONE : int = 748895195

	class BIOME:
		const GROUP : int = 835576787
	
		class STATE:
			const CANYON : int = 2927127661
			const CITY : int = 3888786832
			const DESERT : int = 1850388778
			const FOREST : int = 491961918
			const FUMEROLE : int = 3463627824
			const GLASS : int = 2449969375
			const JUNGLE : int = 219304270
			const NONE : int = 748895195
			const VOLCAN : int = 2949866374

	class DAY_CYCLE:
		const GROUP : int = 4021126918
	
		class STATE:
			const DAWN : int = 2009803003
			const DAY : int = 311764537
			const DUSK : int = 2348606646
			const NIGHT : int = 1011622525
			const NONE : int = 748895195

	class PLANET:
		const GROUP : int = 1602519891
	
		class STATE:
			const GAEEA : int = 2972501404
			const NONE : int = 748895195
			const SANDBOX : int = 222378406

	class SHIPRADIO:
		const GROUP : int = 2292734492
	
		class STATE:
			const NONE : int = 748895195

	class BACKGROUND_MUSIC:
		const GROUP : int = 1585661381
	
		class STATE:
			const NONE : int = 748895195
			const MENU : int = 2607556080
			const SANDBOX : int = 222378406

	class CLOTHESTYPE:
		const GROUP : int = 3707611735
	
		class STATE:
			const ARMOR : int = 662199250
			const CIVIL : int = 1732323826
			const EVA : int = 932389257
			const EXOHEAVY : int = 2203034062
			const EXOLIGHT : int = 761313835
			const EXOMIDDLE : int = 2102108254
			const NAKED : int = 3493061874
			const NONE : int = 748895195

	class PLAYERSTATE:
		const GROUP : int = 3285234865
	
		class STATE:
			const ALIVE : int = 655265632
			const DEAD : int = 2044049779
			const NONE : int = 748895195

	class WEATHERTYPE:
		const GROUP : int = 2193502539
	
		class STATE:
			const CLEAR : int = 1754255536
			const DUST : int = 2348606633
			const NONE : int = 748895195
			const RAIN : int = 2043403999
			const SNOW : int = 787898836
			const STORM : int = 1686739424
			const WINDY : int = 742231792

	class GAMESTATUES:
		const GROUP : int = 2508892538
	
		class STATE:
			const INGAME : int = 984691642
			const INMENU : int = 3374585465
			const NONE : int = 748895195

	class ROOMSTATE:
		const GROUP : int = 185713839
	
		class STATE:
			const INDOOR : int = 340398852
			const NONE : int = 748895195
			const OUTDOOR : int = 144697359


class SWITCHES:

	class GROUNDWETTNESS:
		const GROUP : int = 2365304977
	
		class SWITCH:
			const DAMP : int = 1842026663
			const DRY : int = 630539344
			const SOAKED : int = 1905651656
			const WET : int = 1181096339

	class IMPACTMATERIAL:
		const GROUP : int = 4034326400
	
	class SURFACETYPE:
		const GROUP : int = 63790334
	
		class SWITCH:
			const ASPHALT : int = 4169408098
			const CEMENT : int = 3725073853
			const CERAMIC : int = 1968058251
			const CONCRETE : int = 841620460
			const DEFAULT : int = 782826392
			const DIRT : int = 2195636714
			const DIRTPUDDLE : int = 1252535910
			const FABRICS : int = 3542935173
			const FOREST : int = 491961918
			const FORESTPINE : int = 2779768388
			const GALIUM : int = 1731304782
			const GLASS : int = 2449969375
			const GLASSBROCKEN : int = 3175670661
			const GRASS : int = 4248645337
			const GRASSPUDDLE : int = 1457384333
			const GRAVEL : int = 2185786256
			const ICE : int = 344481046
			const LAVA : int = 540301611
			const LEAVES : int = 582824249
			const MARBLE : int = 1127618254
			const MARSH : int = 1442397674
			const METAL : int = 2473969246
			const MUD : int = 712897245
			const PEBBLES : int = 655669156
			const PLASTIC : int = 660835419
			const REGOLITE : int = 4097769968
			const ROAD : int = 2110808655
			const ROCK : int = 2144363834
			const RUBBER : int = 437659151
			const RUG : int = 712161697
			const SAND : int = 803837735
			const SNOW : int = 787898836
			const TILES : int = 3316001432
			const WATERSHALLOW : int = 542275950
			const WOOD : int = 2058049674
			const WOODFLOOR : int = 3111880208

	class VEGETATIONHEIGHT:
		const GROUP : int = 1333296952
	
		class SWITCH:
			const HI : int = 1769415228
			const LOW : int = 545371365
			const MIDDLE : int = 1026627430
			const NO : int = 1668749452

	class PLAYERHEALTH:
		const GROUP : int = 151362964
	
		class SWITCH:
			const FULLHEALTH : int = 2429688720
			const LOWHEALTH : int = 1017222595
			const NEARDEATH : int = 898449699

	class PLAYERSPEED:
		const GROUP : int = 1493153371
	
		class SWITCH:
			const RUN : int = 712161704
			const SNEAK : int = 2884887403
			const SPRINT : int = 1296465089
			const WALK : int = 2108779966

	class PLAYERSTAND:
		const GROUP : int = 2916127318
	
		class SWITCH:
			const CRAWL : int = 3115216662
			const CROUCH : int = 2655407367
			const EVA : int = 932389257
			const INATMOSPHERE : int = 2844196668
			const INSPACE : int = 1122646526
			const RUN : int = 712161704
			const SIT : int = 577793763
			const SPRINT : int = 1296465089
			const STAND : int = 1214700371
			const SWIM : int = 151879501
			const UNDERWATER : int = 2213237662
			const WALK : int = 2108779966

	class PLAYERTEMP:
		const GROUP : int = 2832092308
	
		class SWITCH:
			const COLD : int = 3687161267
			const FREEZING : int = 2323192249
			const HOT : int = 1082843450
			const NORMAL : int = 1160234136

	class SHOETYPE:
		const GROUP : int = 2413944604
	
		class SWITCH:
			const FS_BAREFEET : int = 1965097039
			const FS_CIVILSCHOES : int = 3645706237
			const FS_MAGBOOTS : int = 1342034631

	class VEHICULESTART:
		const GROUP : int = 1248815374
	
		class SWITCH:
			const OFF : int = 930712164
			const ON : int = 1651971902

	class VEHICULEGEAR:
		const GROUP : int = 3890757055
	
		class SWITCH:
			const GEAR_1 : int = 1307359308
			const GEAR_2 : int = 1307359311
			const GEAR_3 : int = 1307359310
			const NEUTRAL : int = 670611050

	class REFLECTIONTYPE:
		const GROUP : int = 2607665550
	
		class SWITCH:
			const ABSORBANT : int = 1931611597

	class TOOLTYPE:
		const GROUP : int = 3220052683
	
	class WEAPONTYPE:
		const GROUP : int = 767731869
	

class GAME_PARAMETERS:

	const CITYACTIVITY : int = 1651977279
	const TREEDENSITY : int = 1317162623
	const AIRDENSITY : int = 677211493
	const GRAVITYWEIGHT : int = 2075977377
	const GROUNDWETNESS : int = 659943165
	const SURFACETYPE : int = 63790334
	const VEGETATIONHEIGHT : int = 1333296952
	const WATERDEPTH : int = 1354718973
	const AMBIENCE_FADER : int = 515145112
	const MASTER_FADER : int = 662992330
	const MUSIC_FADER : int = 3989812379
	const SFX_FADER : int = 2954701363
	const UI_FADER : int = 2228480122
	const VOIP_FADER : int = 1219006434
	const VOIX_FADER : int = 4006546922
	const PLAYERENDURANCE : int = 3408921745
	const PLAYERHEALTH : int = 151362964
	const PLAYERMASS : int = 2486003682
	const PLAYERO2 : int = 3574019025
	const PLAYERSPEED : int = 1493153371
	const GEARNUMBER : int = 830810011
	const RPM : int = 796049864
	const SLIP : int = 686938995
	const SPEED : int = 640949982
	const SUSPENSIONTRAVEL : int = 240939038
	const THROTTLE : int = 2995819693
	const RAININTENSITY : int = 1866329414
	const THUNDERDISTANCE : int = 2069415960
	const WAVEINTENSITY : int = 755180541
	const WEATHERINTENSITY : int = 1573022778
	const WINDINTENSITY : int = 1042517418
	const WINDSPEED : int = 1726592700
	const WINDTONAL : int = 2950718229
	const ACTIONINTENSITY : int = 136645486
	const DISTANCE : int = 1240670792
	const IMPACTFORCE : int = 1642941132
	const OTHERPLAYERDENSITY : int = 3319037818

class TRIGGERS:
	pass

class BANKS:

	const BENCHMARK : int = 1961141322
	const DEBUGS_AUDIO : int = 1792379286
	const LOADINGMENU : int = 600414130
	const GITLFS_100MO : int = 749173584
	const INERACT_GLOBAL : int = 1085394087
	const MUSIC_GLOBAL : int = 2880921812
	const PLAYER_GLOBAL : int = 957994328
	const SYSTEM_GLOBAL : int = 2826473784
	const WEAPONS_GLOBAL : int = 2276827214
	const SANDBOX_AMBIENCE_CITY : int = 11835353
	const SANDBOX_AMBIENCE_CITY_03 : int = 3161529799
	const SANDBOX_AMBIENCE_DESERT : int = 2460918679
	const SANDBOX_AMBIENCE_VILLAGE : int = 1720272332

class AUX_BUSSES:
	pass

class ACOUSTIC_TEXTURES:

	const ACOUSTIC_BANNER : int = 4168643977
	const ANECHOIC : int = 1873957695
	const BRICK : int = 504532776
	const CARPET : int = 2412606308
	const CONCRETE : int = 841620460
	const CORK_TILES : int = 3195498748
	const CURTAINS : int = 2928161104
	const DRYWALL : int = 3670307564
	const FABRIC : int = 1970351858
	const MOUNTAIN : int = 513139656
	const TILE : int = 2637588553
	const WOOD : int = 2058049674
	const WOOD_BRIGHT : int = 4262522749
	const WOOD_DEEP : int = 1755085759

