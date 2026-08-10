#if canImport(UIKit)
import SwiftUI

/// A small pill showing the current checkout phase with a status-appropriate
/// color and label.
struct StatusBadge: View {
    let phase: ZuuppaPhase

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private var label: String {
        switch phase {
        case .awaitingPayment: return "Waiting for payment"
        case .underpaid: return "Underpaid"
        case .settling: return "Payment received"
        case .settled: return "Paid"
        case .expired: return "Expired"
        case .refunding: return "Refunding"
        case .refunded: return "Refunded"
        case .refundFailed: return "Refund issue"
        case .cancelled: return "Cancelled"
        }
    }

    private var color: Color {
        switch phase {
        case .awaitingPayment: return ZuuppaColor.textSecondary
        case .underpaid: return ZuuppaColor.warning
        case .settling: return ZuuppaColor.accent
        case .settled: return ZuuppaColor.success
        case .expired: return ZuuppaColor.textTertiary
        case .refunding: return ZuuppaColor.warning
        case .refunded: return ZuuppaColor.accent
        case .refundFailed: return ZuuppaColor.danger
        case .cancelled: return ZuuppaColor.textTertiary
        }
    }
}
#endif
