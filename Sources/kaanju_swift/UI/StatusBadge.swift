#if canImport(UIKit)
import SwiftUI

/// A small pill showing the current checkout phase with a status-appropriate
/// color and label.
struct StatusBadge: View {
    let phase: KaanjuPhase

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
        case .awaitingPayment: return KaanjuColor.textSecondary
        case .underpaid: return KaanjuColor.warning
        case .settling: return KaanjuColor.accent
        case .settled: return KaanjuColor.success
        case .expired: return KaanjuColor.textTertiary
        case .refunding: return KaanjuColor.warning
        case .refunded: return KaanjuColor.accent
        case .refundFailed: return KaanjuColor.danger
        case .cancelled: return KaanjuColor.textTertiary
        }
    }
}
#endif
