import SwiftUI

struct OutdoorActivityReviewView: View {
    let activity: OutdoorActivity

    var body: some View {
        Text(activity.activityType.displayName)
    }
}
