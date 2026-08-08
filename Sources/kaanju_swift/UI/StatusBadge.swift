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
        }
    }

    private var color: Color {
        switch phase {
        case .awaitingPayment: return .secondary
        case .underpaid: return .orange
        case .settling: return .blue
        case .settled: return .green
        case .expired: return .gray
        case .refunding: return .orange
        case .refunded: return .blue
        case .refundFailed: return .red
        }
    }
}
#endif
