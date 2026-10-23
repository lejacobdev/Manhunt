#if DEBUG
import Foundation

extension ScreenshotScenario {
    /// The Customize screen's sample store, for the simulator scenario and the in-app purchase
    /// review screenshot.
    static var sampleCosmetics: CosmeticsSnapshot {
        decode(#"""
        {"items":[
          {"id":"map.standard","category":"mapStyle","name":"Standard","description":"The classic dark map.","unlock":"free","productId":null,"requirement":null,"progress":null,"goal":null,"owned":true},
          {"id":"map.muted","category":"mapStyle","name":"Night Ops","description":"A muted map.","unlock":"play","productId":null,"requirement":"Play 5 matches","progress":5,"goal":5,"owned":true},
          {"id":"map.satellite","category":"mapStyle","name":"Satellite","description":"Aerial imagery.","unlock":"pack","productId":"com.huntinggame.app.pack.maps","requirement":null,"progress":null,"goal":null,"owned":false},
          {"id":"map.hybrid","category":"mapStyle","name":"Hybrid","description":"Imagery with streets.","unlock":"pack","productId":"com.huntinggame.app.pack.maps","requirement":null,"progress":null,"goal":null,"owned":false},
          {"id":"radar.classic","category":"radarSkin","name":"Classic","description":"Your role colour.","unlock":"free","productId":null,"requirement":null,"progress":null,"goal":null,"owned":true},
          {"id":"radar.ghost","category":"radarSkin","name":"Ghost","description":"Violet sweep.","unlock":"play","productId":null,"requirement":"Win 10 matches","progress":6,"goal":10,"owned":false},
          {"id":"radar.arctic","category":"radarSkin","name":"Arctic","description":"Ice-blue sweep.","unlock":"pack","productId":"com.huntinggame.app.pack.radar","requirement":null,"progress":null,"goal":null,"owned":false},
          {"id":"radar.gold","category":"radarSkin","name":"Gold","description":"Gold sweep.","unlock":"pack","productId":"com.huntinggame.app.pack.radar","requirement":null,"progress":null,"goal":null,"owned":false},
          {"id":"marker.default","category":"marker","name":"Standard","description":"The role figure.","unlock":"free","productId":null,"requirement":null,"progress":null,"goal":null,"owned":true},
          {"id":"marker.hare","category":"marker","name":"Hare","description":"Hard to catch.","unlock":"play","productId":null,"requirement":"Make 25 catches","progress":11,"goal":25,"owned":false},
          {"id":"marker.flame","category":"marker","name":"Flame","description":"A flame.","unlock":"pack","productId":"com.huntinggame.app.pack.markers","requirement":null,"progress":null,"goal":null,"owned":false},
          {"id":"banner.default","category":"banner","name":"Standard","description":"Cyan.","unlock":"free","productId":null,"requirement":null,"progress":null,"goal":null,"owned":true},
          {"id":"banner.ember","category":"banner","name":"Ember","description":"Red to amber.","unlock":"pack","productId":"com.huntinggame.app.pack.banners","requirement":null,"progress":null,"goal":null,"owned":false},
          {"id":"badge.none","category":"badge","name":"None","description":"No badge.","unlock":"free","productId":null,"requirement":null,"progress":null,"goal":null,"owned":true},
          {"id":"badge.supporter","category":"badge","name":"Supporter","description":"Thanks for supporting.","unlock":"supporter","productId":"com.huntinggame.app.supporter","requirement":null,"progress":null,"goal":null,"owned":false}],
         "products":[
          {"productId":"com.huntinggame.app.pack.maps","name":"Map Pack","description":"Satellite and Hybrid map styles.","items":[],"owned":false},
          {"productId":"com.huntinggame.app.pack.radar","name":"Radar Skins","description":"Arctic, Gold and Mono radar sweeps.","items":[],"owned":false},
          {"productId":"com.huntinggame.app.pack.markers","name":"Marker Pack","description":"Bolt, Flame, Star and Paw map markers.","items":[],"owned":false},
          {"productId":"com.huntinggame.app.pack.banners","name":"Banner Pack","description":"Ember, Ice and Aurora profile banners.","items":[],"owned":false},
          {"productId":"com.huntinggame.app.supporter","name":"Supporter","description":"Every pack, plus a Supporter badge, banner and radar. Keeps Hunting Game free and ad-free.","items":[],"owned":false}],
         "equipped":{"mapStyle":"map.muted","radarSkin":"radar.classic","marker":"marker.default","banner":"banner.default","badge":"badge.none"}}
        """#)
    }
}
#endif
